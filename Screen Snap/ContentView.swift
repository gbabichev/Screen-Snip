


import SwiftUI
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import UniformTypeIdentifiers
import ImageIO

// MARK: - NSColor Hex Conversion Helper (no RawRepresentable conformance)
extension NSColor {
    /// Initialize from hex string like "#RRGGBB" or "#RRGGBBAA" (case-insensitive)
    convenience init?(hexRGBA: String) {
        let trimmed = hexRGBA.trimmingCharacters(in: .whitespacesAndNewlines)
        var hex = trimmed.replacingOccurrences(of: "#", with: "").uppercased()
        if hex.count == 6 { hex += "FF" }
        guard hex.count == 8, let val = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((val >> 24) & 0xFF) / 255.0
        let g = CGFloat((val >> 16) & 0xFF) / 255.0
        let b = CGFloat((val >> 8)  & 0xFF) / 255.0
        let a = CGFloat( val        & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Convert to hex string `#RRGGBBAA` in sRGB
    func toHexRGBA() -> String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#000000FF" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = UInt8(round(r * 255))
        let gi = UInt8(round(g * 255))
        let bi = UInt8(round(b * 255))
        let ai = UInt8(round(a * 255))
        return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
    }
}


private enum Tool { case pointer, line, rect, oval, text, crop, badge, highlighter }

private enum SaveFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic
    var id: String { rawValue }
    var utType: UTType {
        switch self {
        case .png:  return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }
    var fileExtension: String {
        switch self {
        case .png:  return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
}

struct ContentView: View {
    
    @State private var thumbnailRefreshTrigger = UUID()

    @State private var selectedImageSize: CGSize? = nil
    @State private var imageReloadTrigger = UUID()
    @State private var missingSnapURLs: Set<URL> = []
    @State private var zoomLevel: Double = 1.0
    @State private var pinchBaseZoom: Double? = nil
    
    @State private var showSettingsPopover = false
    @AppStorage("preferredSaveFormat") private var preferredSaveFormatRaw: String = SaveFormat.png.rawValue
    private var preferredSaveFormat: SaveFormat {
        get { SaveFormat(rawValue: preferredSaveFormatRaw) ?? .png }
        set { preferredSaveFormatRaw = newValue.rawValue }
    }
    
    @AppStorage("saveQuality") private var saveQuality: Double = 0.9
    @AppStorage("saveDirectoryPath") private var saveDirectoryPath: String = ""
    @AppStorage("downsampleToNonRetinaClipboard") private var downsampleToNonRetinaClipboard: Bool = false
    @AppStorage("downsampleToNonRetinaForSave") private var downsampleToNonRetinaForSave: Bool = false
    @AppStorage("imageDisplayMode") private var imageDisplayMode: String = "actual" // "actual" or "fit"
    @AppStorage("saveOnCopy") private var saveOnCopy: Bool = true

    
    private enum ImporterKind { case image, folder }
    @State private var activeImporter: ImporterKind? = nil
    
    @FocusState private var isTextEditorFocused: Bool
    
    @State private var focusedTextID: UUID? = nil
    @State private var showCopiedHUD = false
    @State private var selectedTool: Tool = .pointer
    // Removed lines buffer; we now auto-commit each line on mouse-up.
    @State private var draft: Line? = nil
    @State private var draftRect: CGRect? = nil
    @State private var cropDraftRect: CGRect? = nil
    @State private var cropRect: CGRect? = nil
    @State private var cropHandle: Handle = .none
    @State private var cropDragStart: CGPoint? = nil
    @State private var cropOriginalRect: CGRect? = nil
    @State private var strokeWidth: CGFloat = 3
    @AppStorage("lineColor") private var lineColorRaw: String = "#000000FF"
    private var lineColor: NSColor {
        get { NSColor(hexRGBA: lineColorRaw) ?? .black }
        set { lineColorRaw = newValue.toHexRGBA() }
    }
    private var lineColorBinding: Binding<NSColor> {
        Binding(
            get: { lineColor },
            set: { newValue in
                lineColorRaw = newValue.toHexRGBA()
            }
        )
    }
    @AppStorage("rectColor") private var rectColorRaw: String = "#000000FF"
    private var rectColor: NSColor {
        get { NSColor(hexRGBA: rectColorRaw) ?? .black }
        set { rectColorRaw = newValue.toHexRGBA() }
    }
    private var rectColorBinding: Binding<NSColor> {
        Binding(
            get: { rectColor },
            set: { newValue in rectColorRaw = newValue.toHexRGBA() }
        )
    }
    @AppStorage("ovalColor") private var ovalColorRaw: String = "#000000FF"
    private var ovalColor: NSColor {
        get { NSColor(hexRGBA: ovalColorRaw) ?? .black }
        set { ovalColorRaw = newValue.toHexRGBA() }
    }
    private var ovalColorBinding: Binding<NSColor> {
        Binding(
            get: { ovalColor },
            set: { newValue in ovalColorRaw = newValue.toHexRGBA() }
        )
    }
    @State private var lineHasArrow: Bool = false
    // Snaps persisted on disk (newest first). Each element is a file URL to a PNG.
    @State private var snapURLs: [URL] = []
    @State private var selectedSnapURL: URL? = nil
    @State private var objects: [Drawable] = []
    @State private var selectedObjectID: UUID? = nil
    @State private var activeHandle: Handle = .none
    @State private var dragStartPoint: CGPoint? = nil
    
    // Undo/Redo stacks of full images and overlays (save-in-place, memory-bounded by user behavior)
    private struct Snapshot {
        let imageURL: URL?
        let objects: [Drawable]
    }
    
    @State private var undoStack: [Snapshot] = []
    @State private var redoStack: [Snapshot] = []
    @State private var pushedDragUndo = false
    @State private var keyMonitor: Any? = nil
    
    @State private var textFontSize: CGFloat = 18
    
    @AppStorage("textColor") private var textColorRaw: String = "#FFFFFFFF"
    private var textColor: NSColor {
        get { NSColor(hexRGBA: textColorRaw) ?? .white }
        set { textColorRaw = newValue.toHexRGBA() }
    }
    private var textColorBinding: Binding<NSColor> {
        Binding(get: { textColor }, set: { textColorRaw = $0.toHexRGBA() })
    }
    
    @State private var textBGEnabled: Bool = true
    
    @AppStorage("textBGColor") private var textBGColorRaw: String = "#00000099"
    private var textBGColor: NSColor {
        get { NSColor(hexRGBA: textBGColorRaw) ?? NSColor.black.withAlphaComponent(0.6) }
        set { textBGColorRaw = newValue.toHexRGBA() }
    }
    private var textBGColorBinding: Binding<NSColor> {
        Binding(get: { textBGColor }, set: { textBGColorRaw = $0.toHexRGBA() })
    }
    
    @AppStorage("badgeColor") private var badgeColorRaw: String = "#FF0000FF"
    private var badgeColor: NSColor {
        get { NSColor(hexRGBA: badgeColorRaw) ?? .red }
        set { badgeColorRaw = newValue.toHexRGBA() }
    }
    private var badgeColorBinding: Binding<NSColor> {
        Binding(get: { badgeColor }, set: { badgeColorRaw = $0.toHexRGBA() })
    }
    
    @State private var badgeCount: Int = 0
    
    @AppStorage("highlighterColor") private var highlighterColorRaw: String = "#FFFF59FF"
    private var highlighterColor: NSColor {
        get { NSColor(hexRGBA: highlighterColorRaw) ?? NSColor.systemYellow.withAlphaComponent(0.35) }
        set { highlighterColorRaw = newValue.toHexRGBA() }
    }
    private var highlighterColorBinding: Binding<NSColor> {
        Binding(get: { highlighterColor }, set: { highlighterColorRaw = $0.toHexRGBA() })
    }
    
    @State private var lastFittedSize: CGSize? = nil
    @State private var objectSpaceSize: CGSize? = nil  // tracks the UI coordinate space size the objects are authored in
    
    @State private var lastDraftTick: CFTimeInterval = 0
    
    // Throttle rapid draft updates to ~90 Hz (for drag gestures)
    private func allowDraftTick(interval: Double = 1.0/90.0) -> Bool {
        let now = CACurrentMediaTime()
        if now - lastDraftTick < interval { return false }
        lastDraftTick = now
        return true
    }
    
    private func getActualDisplaySize(_ pixelSize: CGSize) -> CGSize {
        guard let url = selectedSnapURL else { return pixelSize }
        
        // Load NSImage to get proper point size (retina-aware)
        if let nsImage = NSImage(contentsOf: url) {
            return nsImage.size  // This gives you 1440x900 for a 2880x1800 retina image
        }
        
        // Fallback detection
        if pixelSize.width > 1800 || pixelSize.height > 1800 {
            return CGSize(width: pixelSize.width / 2, height: pixelSize.height / 2)
        }
        
        return pixelSize
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Main canvas
            VStack(spacing: 12) {
                
                
                Group {
                    if let url = selectedSnapURL, let imgSize = selectedImageSize {
                        GeometryReader { geo in
                            let baseFitted = imageDisplayMode == "fit"
                                ? fittedImageSize(original: getActualDisplaySize(imgSize), in: geo.size)  // Use point size for fitting
                                : getActualDisplaySize(imgSize)  // Use point size for actual
                            let fitted = CGSize(width: baseFitted.width * zoomLevel,
                                                height: baseFitted.height * zoomLevel)

                            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                                ZStack {
                                    let author = objectSpaceSize ?? baseFitted
                                    let sx = fitted.width / max(1, author.width)
                                    let sy = fitted.height / max(1, author.height)
                                    let scaledSize = CGSize(width: author.width * sx, height: author.height * sy)
                                    let origin = CGPoint(
                                        x: max(0, (fitted.width  - scaledSize.width)  / 2),
                                        y: max(0, (fitted.height - scaledSize.height) / 2)
                                    )

                                    // Base image streamed without holding NSImage in @State
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let img):
                                            img.resizable()
                                               .interpolation(.high)
                                               .frame(width: fitted.width, height: fitted.height)
                                        case .empty:
                                            ProgressView()
                                                .frame(width: fitted.width, height: fitted.height)
                                        case .failure(_):
                                            Color.secondary.opacity(0.1)
                                                .frame(width: fitted.width, height: fitted.height)
                                                .overlay(
                                                    VStack(spacing: 6) {
                                                        Image(systemName: "exclamationmark.triangle")
                                                        Text("Failed to load image")
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                )
                                        @unknown default:
                                            Color.clear.frame(width: fitted.width, height: fitted.height)
                                        }
                                    }
                                    .id(imageReloadTrigger)

                                    // Object Overlay
                                    
                                    ZStack {
                                        // Persisted objects
                                        ForEach(objects) { obj in
                                            switch obj {
                                            case .line(let o):
                                                let base = o.drawPath(in: author)
                                                
                                                // If arrow, create a shortened path that stops at arrow base
                                                if o.arrow {
                                                    let dx = o.end.x - o.start.x
                                                    let dy = o.end.y - o.start.y
                                                    let len = max(1, hypot(dx, dy))
                                                    let ux = dx / len, uy = dy / len
                                                    
                                                    let desired = max(16, o.width * 6.0)
                                                    let capped = min(len * 0.35, 280)
                                                    let headLength = min(desired, capped)
                                                    
                                                    // Calculate where line should end (at arrow base)
                                                    let lineEnd = CGPoint(x: o.end.x - ux * headLength, y: o.end.y - uy * headLength)
                                                    
                                                    // Draw shortened line
                                                    Path { p in
                                                        p.move(to: o.start)
                                                        p.addLine(to: lineEnd)
                                                    }
                                                    .stroke(Color(nsColor: o.color),
                                                            style: StrokeStyle(lineWidth: o.width, lineCap: .butt))
                                                } else {
                                                    // Normal line without arrow
                                                    base.stroke(Color(nsColor: o.color),
                                                                style: StrokeStyle(lineWidth: o.width, lineCap: .round))
                                                }
                                                
                                                if o.arrow {
                                                    arrowHeadPath(from: o.start, to: o.end, lineWidth: o.width)
                                                        .fill(Color(nsColor: o.color))
                                                }
                                            case .rect(let o):
                                                o.drawPath(in: author)
                                                    .stroke(Color(nsColor: o.color),
                                                            style: StrokeStyle(lineWidth: o.width))
                                            case .oval(let o):
                                                Ellipse()
                                                    .path(in: o.rect)
                                                    .stroke(Color(nsColor: o.color),
                                                            style: StrokeStyle(lineWidth: o.width))
                                            case .text(let o):
                                                if focusedTextID != o.id {
                                                    Text(o.text.isEmpty ? " " : o.text)
                                                        .font(.system(size: o.fontSize))
                                                        .foregroundStyle(Color(nsColor: o.textColor))
                                                        .frame(width: o.rect.width, height: o.rect.height, alignment: .topLeading)
                                                        .padding(4)
                                                        .background(o.bgEnabled ? Color(nsColor: o.bgColor) : Color.clear)
                                                        .position(x: o.rect.midX, y: o.rect.midY)
                                                }
                                            case .badge(let o):
                                                Circle()
                                                    .fill(Color(nsColor: o.fillColor))
                                                    .frame(width: o.rect.width, height: o.rect.height)
                                                    .position(x: o.rect.midX, y: o.rect.midY)
                                                    .overlay {
                                                        Text("\(o.number)")
                                                            .font(.system(size: max(10, min(o.rect.width, o.rect.height) * 0.6), weight: .bold))
                                                            .foregroundStyle(Color(nsColor: o.textColor))
                                                            .position(x: o.rect.midX, y: o.rect.midY)
                                                    }
                                            case .highlight(let o):
                                                Rectangle()
                                                    .fill(Color(nsColor: o.color))
                                                    .frame(width: o.rect.width, height: o.rect.height)
                                                    .position(x: o.rect.midX, y: o.rect.midY)
                                            case .image(let o):
                                                Image(nsImage: o.image)
                                                    .resizable()
                                                    .interpolation(.high)
                                                    .frame(width: o.rect.width, height: o.rect.height)
                                                    .position(x: o.rect.midX, y: o.rect.midY)
                                            }
                                        }

                                        // MOVE SELECTION HANDLES INSIDE THE SCALED CONTEXT
                                        if let sel = selectedObjectID, let idx = objects.firstIndex(where: { $0.id == sel }) {
                                            switch objects[idx] {
                                            case .line(let o):  selectionHandlesForLine(o)
                                            case .rect(let o):  selectionHandlesForRect(o)
                                            case .oval(let o):  selectionHandlesForOval(o)
                                            case .text(let o):  selectionHandlesForText(o)
                                            case .badge(let o): selectionHandlesForBadge(o)
                                            case .highlight(let o): selectionHandlesForHighlight(o)
                                            case .image(let o): selectionHandlesForImage(o)
                                            }
                                        }

                                        // Drafts, crop visuals — leave exactly as your code has them
                                        if let d = draft {
                                            Path { p in p.move(to: d.start); p.addLine(to: d.end) }
                                                .stroke(Color(nsColor: lineColor).opacity(0.8),
                                                        style: StrokeStyle(lineWidth: d.width, dash: [6,4]))
                                            if imageDisplayMode != "fit" && lineHasArrow {
                                                arrowHeadPath(from: d.start, to: d.end, lineWidth: d.width)
                                                    .fill(Color(nsColor: lineColor).opacity(0.8))
                                            }
                                        }

                                        if let r = draftRect {
                                            switch selectedTool {
                                            case .rect:
                                                Rectangle()
                                                    .path(in: r)
                                                    .stroke(imageDisplayMode == "fit" ? .secondary : Color(nsColor: rectColor).opacity(0.8),
                                                            style: StrokeStyle(lineWidth: imageDisplayMode == "fit" ? max(1, strokeWidth) : strokeWidth, dash: [6,4]))
                                            case .highlighter:
                                                Rectangle().path(in: r).fill(Color(nsColor: highlighterColor))
                                            case .oval:
                                                if imageDisplayMode != "fit" {
                                                    Ellipse().path(in: r)
                                                        .stroke(Color(nsColor: rectColor).opacity(0.8),
                                                                style: StrokeStyle(lineWidth: strokeWidth, dash: [6,4]))
                                                }
                                            case .line:
                                                EmptyView()
                                            default:
                                                EmptyView()
                                            }
                                        }

                                        if let crp = cropRect {
                                            Rectangle().path(in: crp)
                                                .stroke(Color.orange.opacity(0.95),
                                                        style: StrokeStyle(lineWidth: max(1, strokeWidth), dash: [8,4]))
                                                .overlay(Rectangle().path(in: crp).fill(Color.orange.opacity(0.10)))

                                            let pts = [
                                                CGPoint(x: crp.minX, y: crp.minY),
                                                CGPoint(x: crp.maxX, y: crp.minY),
                                                CGPoint(x: crp.minX, y: crp.maxY),
                                                CGPoint(x: crp.maxX, y: crp.maxY)
                                            ]
                                            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                                                Circle().stroke(Color.orange, lineWidth: 1)
                                                    .background(Circle().fill(Color.white))
                                                    .frame(width: 12, height: 12)
                                                    .position(pt)
                                            }
                                        }

                                        if let cr = cropDraftRect {
                                            Rectangle().path(in: cr)
                                                .stroke(Color.orange.opacity(0.9),
                                                        style: StrokeStyle(lineWidth: max(1, strokeWidth), dash: [8,4]))
                                                .overlay(Rectangle().path(in: cr).fill(Color.orange.opacity(0.12)))
                                        }
                                    }
                                    .frame(width: author.width, height: author.height)
                                    .scaleEffect(x: sx, y: sy, anchor: .center)
                                    .frame(width: fitted.width, height: fitted.height, alignment: .center)
                                    .transaction { $0.disablesAnimations = true }
                                    .compositingGroup()
                                    .drawingGroup()
                                    // REMOVE the .overlay(alignment: .topLeading) block entirely
                                    .contentShape(Rectangle())
                                    .allowsHitTesting(true)
                                    .onTapGesture(count: 2) {
                                        // Only allow double-tap zoom when using the pointer tool and not in fit mode
                                        guard selectedTool == .pointer && imageDisplayMode != "fit" else {
                                            print("Double tap ignored - wrong tool or fit mode")
                                            return
                                        }
                                        
                                        print("Double tap zoom activated!")
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            if zoomLevel < 1.5 {
                                                zoomLevel = 2.0
                                            } else {
                                                zoomLevel = 1.0
                                            }
                                        }
                                    }
                                    .simultaneousGesture(selectedTool == .pointer    ? pointerGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                    .simultaneousGesture(selectedTool == .line       ? lineGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .rect       ? rectGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .oval       ? ovalGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .text       ? textGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .crop       ? cropGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .badge      ? badgeGesture(insetOrigin: origin, fitted: fitted, author: author)   : nil)
                                    .simultaneousGesture(selectedTool == .highlighter ? highlightGesture(insetOrigin: origin, fitted: fitted, author: author): nil)


                                    .simultaneousGesture(selectedTool == .pointer    ? pointerGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                    .simultaneousGesture(selectedTool == .line       ? lineGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .rect       ? rectGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .oval       ? ovalGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .text       ? textGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .crop       ? cropGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .badge      ? badgeGesture(insetOrigin: origin, fitted: fitted, author: author)   : nil)
                                    .simultaneousGesture(selectedTool == .highlighter ? highlightGesture(insetOrigin: origin, fitted: fitted, author: author): nil)
                                    .onAppear {
                                        lastFittedSize = baseFitted
                                        if objectSpaceSize == nil { objectSpaceSize = baseFitted }
                                    }
                                    
                                }
                                .frame(width: fitted.width, height: fitted.height)
                                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .center)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(
                                LocalScrollWheelZoomView(zoomLevel: $zoomLevel, minZoom: 1.0, maxZoom: 3.0)
                                    .allowsHitTesting(true)
                            )
                            .gesture(
                                MagnificationGesture(minimumScaleDelta: 0.01)
                                    .onChanged { scale in
                                        if pinchBaseZoom == nil { pinchBaseZoom = zoomLevel }
                                        let proposed = (pinchBaseZoom ?? zoomLevel) * Double(scale)
                                        zoomLevel = min(max(proposed, 1.0), 3.0)
                                    }
                                    .onEnded { _ in pinchBaseZoom = nil }
                            )
                        }
                    } else {
                        // your empty/missing states unchanged
                        VStack(spacing: 12) {
                            if !missingSnapURLs.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle").imageScale(.large).foregroundStyle(.orange)
                                    Text("Some images were deleted from disk").fontWeight(.medium)
                                    Text("Press ⇧⌘2 to capture a new screenshot").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if !snapURLs.isEmpty {
                                Image(systemName: "camera").imageScale(.large).foregroundStyle(.tint)
                                Text("Press ⇧⌘2 or click 'Capture Region' to begin.")
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "camera").imageScale(.large).foregroundStyle(.tint)
                                Text("Press ⇧⌘2 or click 'Capture Region' to begin.")
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
                
            }
            
            if showCopiedHUD {
                CopiedHUD()
                    .transition(.scale)
                    .padding(20)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !snapURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    
                    HStack(spacing: 6) {
                        Text("Snaps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Button(action: {
                            loadExistingSnaps()
                            thumbnailRefreshTrigger = UUID()
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh snaps")
                        
                        Button(action: {
                            openSnapsInFinder()
                        }) {
                            Image(systemName: "folder")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Open Snaps in Finder")
                        
                        Button(action: {
                            openSnapsInGallery()
                        }) {
                            Image(systemName: "square.grid.2x2")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Open Snaps Gallery")
                        
                        
                    }
                    .padding(.leading, 8)
                    
                    
                    
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) {
                            ForEach(snapURLs, id: \.self) { url in
                                VStack(spacing: 4) {
                                    ThumbnailView(
                                        url: url,
                                        selected: selectedSnapURL == url,
                                        onDelete: { deleteSnap(url) },
                                        width: 140,
                                        height: 90,
                                        refreshTrigger: thumbnailRefreshTrigger
                                    )

                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 140)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // Check if file exists before trying to load
                                    let fm = FileManager.default
                                    if !fm.fileExists(atPath: url.path) {
                                        // File is missing - add to missing set and remove from snapURLs
                                        missingSnapURLs.insert(url)
                                        if let index = snapURLs.firstIndex(of: url) {
                                            snapURLs.remove(at: index)
                                        }
                                        // If this was the selected snap, clear selection and show error
                                        if selectedSnapURL == url {
                                            selectedSnapURL = nil
                                        }
                                        return
                                    }
                                    
                                    // File exists - load it into the editor
                                    selectedSnapURL = url
                                    selectedImageSize = probeImageSize(url)
                                    updateMenuState()
                                    // Clear all editing state when switching images
                                    objects.removeAll()
                                    objectSpaceSize = nil
                                    selectedObjectID = nil
                                    activeHandle = .none
                                    cropRect = nil
                                    cropDraftRect = nil
                                    cropHandle = .none
                                    focusedTextID = nil
                                    
                                    // Clear undo/redo stacks for the new image
                                    undoStack.removeAll()
                                    redoStack.removeAll()
                                }
                                .contextMenu {
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                }
                .padding(.top, 4)
                .background(.thinMaterial) // keep it distinct and readable
            }
        }
        .onAppear {
            print("🔥 [DEBUG] ContentView.onAppear called")
            loadExistingSnaps()
            updateMenuState()
            // Listen for Cmd+Z / Shift+Cmd+Z globally while this view is active, and Delete for selected objects
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Cmd+Z / Shift+Cmd+Z for Undo/Redo
                if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
                    if chars == "z" {
                        if event.modifierFlags.contains(.shift) {
                            performRedo()
                        } else {
                            performUndo()
                        }
                        return nil // consume
                    }
                    if chars == "v" {
                        // Allow TextEditor to handle paste when editing text; otherwise paste onto canvas
                        if isTextEditorFocused {
                            return event // don't consume; let TextEditor handle paste
                        } else {
                            pasteFromClipboard()
                            return nil // consume
                        }
                    }
                }
                
                // Delete or Forward Delete to remove selected object (no Command modifier)
                if !event.modifierFlags.contains(.command) && (event.keyCode == 51 || event.keyCode == 117) {
                    // If a TextEditor is focused, let it handle character deletion
                    if isTextEditorFocused {
                        return event // do not consume; pass to TextEditor
                    }
                    if selectedObjectID != nil {
                        deleteSelectedObject()
                        return nil // consume so we don't propagate/beep
                    }
                }
                
                // Enter/Return to commit when Crop tool is active
                if selectedTool == .crop, let rect = cropRect, !event.modifierFlags.contains(.command) {
                    if event.keyCode == 36 || event.keyCode == 76 { // Return or Keypad Enter
                        // Perform destructive crop with current overlay
                        if let url = selectedSnapURL {
                            pushUndoSnapshot()
                            if let base = NSImage(contentsOf: url) {
                                let flattened = rasterize(base: base, objects: objects) ?? base

                                // Determine the fitted size currently used for the crop UI
                                let fittedForUI: CGSize = {
                                    if imageDisplayMode == "fit" {
                                        if let imgSize = selectedImageSize,
                                           let windowSize = NSApp.keyWindow?.contentView?.bounds.size {
                                            return fittedImageSize(original: imgSize, in: windowSize)
                                        }
                                    }
                                    // fallback: previous fitted size or image point size
                                    if let s = lastFittedSize { return s }
                                    if let s = objectSpaceSize { return s }
                                    return flattened.size
                                }()

                                // Compute the *pixel* size of the flattened image
                                let imagePxSize = pixelSize(of: flattened)

                                // Map from fitted-space (UI) rect directly into pixel-space (bottom-left origin)
                                let imgRectBL = fittedRectToImageBottomLeftRect(crpRect: rect,
                                                                                fitted: fittedForUI,
                                                                                imagePx: imagePxSize)

                                if let cropped = cropImage(flattened, toBottomLeftRect: imgRectBL) {
                                    // Write the cropped image back to the file
                                    if ImageSaver.writeImage(cropped, to: url, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                                        // Clear all state and reload the cropped image
                                        objects.removeAll()
                                        lastFittedSize = nil
                                        objectSpaceSize = nil
                                        selectedObjectID = nil
                                        activeHandle = .none
                                        cropRect = nil
                                        cropDraftRect = nil
                                        cropHandle = .none
                                        selectedImageSize = probeImageSize(url) // Update the image size
                                        lastFittedSize = nil
                                        imageReloadTrigger = UUID()
                                    }
                                }
                            }
                        }
                        return nil
                    }
                    // Escape cancels current crop overlay
                    if event.keyCode == 53 { // Escape
                        cropRect = nil
                        cropDraftRect = nil
                        cropHandle = .none
                        return nil
                    }
                }

                return event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        }
        // Replace the notification handler in ContentView with this enhanced version:

        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("com.georgebabichev.screensnap.beginSnapFromIntent"))) { note in
            print("🔥 [DEBUG] ContentView received beginSnapFromIntent notification")
            
            // Extract URL and activation flag from userInfo
            guard let userInfo = note.userInfo,
                  let url = userInfo["url"] as? URL else {
                print("🔥 [DEBUG] ERROR: beginSnapFromIntent notification has no URL")
                return
            }
            
            let shouldActivate = userInfo["shouldActivate"] as? Bool ?? true
            
            print("🔥 [DEBUG] beginSnapFromIntent URL: \(url), shouldActivate: \(shouldActivate)")
            
            // CRITICAL: Clear ALL existing state first to prevent memory accumulation
            objects.removeAll()
            objectSpaceSize = nil
            selectedObjectID = nil
            activeHandle = .none
            cropRect = nil
            cropDraftRect = nil
            cropHandle = .none
            focusedTextID = nil
            
            // CRITICAL: Clear undo/redo stacks to prevent memory growth
            undoStack.removeAll()
            redoStack.removeAll()
            
            // CRITICAL: Reset all draft states
            draft = nil
            draftRect = nil
            selectedTool = .pointer
            
            // CRITICAL: Clear any missing snap tracking
            missingSnapURLs.removeAll()
            
            // Refresh the gallery to ensure the new snap is in our list
            loadExistingSnaps()
            
            // Set the selected snap (this should now work since we refreshed)
            selectedSnapURL = url
            selectedImageSize = probeImageSize(url)
            updateMenuState()
            
            print("🔥 [DEBUG] State completely cleared and snap loaded: \(url.lastPathComponent)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectTool)) { note in
            guard let raw = note.userInfo?["tool"] as? String else { return }
            print(raw)
            handleSelectTool(raw)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openImageFile)) { _ in
            activeImporter = .image
        }
        .onReceive(NotificationCenter.default.publisher(for: .copyToClipboard)) { _ in
            // Only copy if we have an image selected
            guard selectedSnapURL != nil else { return }
            flattenRefreshAndCopy()
            selectedTool = .pointer
            selectedObjectID = nil
            activeHandle = .none
            cropDraftRect = nil
            cropRect = nil
            cropHandle = .none
            focusedTextID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .performUndo)) { _ in
            performUndo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .performRedo)) { _ in
            performRedo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveImage)) { _ in
            guard selectedSnapURL != nil else { return }
            flattenAndSaveInPlace()
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveAsImage)) { _ in
            guard selectedSnapURL != nil else { return }
            flattenAndSaveAs()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    activeImporter = .image
                } label: {
                    Label("Open File", systemImage: "folder")
                }
                
                Button { showSettingsPopover = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Settings").font(.headline)
                        Divider()
                        
                        Toggle("Fit image to window", isOn: Binding(
                            get: { imageDisplayMode == "fit" },
                            set: { imageDisplayMode = $0 ? "fit" : "actual" }
                        ))
                        .toggleStyle(.switch)
                        .help("When off, images display at actual size. When on, images scale to fit the window.")
                        
                        Divider()
                        
                        Toggle("Downsample retina screenshots for save", isOn: $downsampleToNonRetinaForSave)
                            .toggleStyle(.switch)
                            .help("When copying to clipboard, convert 2x screenshots to 1x resolution")
                        
                        Toggle("Save on Copy", isOn: $saveOnCopy)
                            .toggleStyle(.switch)
                            .help("Save on copy")
                        
                        Toggle("Downsample retina screenshots for clipboard", isOn: $downsampleToNonRetinaClipboard)
                            .toggleStyle(.switch)
                            .help("When copying to clipboard, convert 2x screenshots to 1x resolution")
                            .disabled(downsampleToNonRetinaForSave && saveOnCopy)
                        
                        
                        Picker("Save format", selection: $preferredSaveFormatRaw) {
                            Text("PNG").tag(SaveFormat.png.rawValue)
                            Text("JPEG").tag(SaveFormat.jpeg.rawValue)
                            Text("HEIC").tag(SaveFormat.heic.rawValue)
                        }
                        .pickerStyle(.segmented)
                        
                        if preferredSaveFormat == .jpeg || preferredSaveFormat == .heic {
                            HStack {
                                Text("Quality")
                                Slider(value: $saveQuality, in: 0.4...1.0)
                                Text(String(format: "%.0f%%", saveQuality * 100))
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                        
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Save destination").font(.subheadline)
                            HStack(spacing: 8) {
                                let pathText = saveDirectoryPath.isEmpty ? "Default (Pictures/Screen Snap)" : saveDirectoryPath
                                Image(systemName: "folder")
                                Text(pathText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Change…") { activeImporter = .folder }
                                if !saveDirectoryPath.isEmpty {
                                    Button("Reset") { saveDirectoryPath = ""; loadExistingSnaps() }
                                }
                            }
                        }
                        
                    }
                    .padding(16)
                    .frame(minWidth: 320)
                }
                
            }
            
            // Items visible only when we have a capture
            if selectedSnapURL != nil {
                
                if imageDisplayMode != "fit"{
                    ToolbarItemGroup(placement: .navigation){
                        HStack {
                            
                            Slider(value: $zoomLevel, in: 1...3) {
                                Text("Zoom")
                            }
                            .frame(width: 80)
                            
                            Button(action: { zoomLevel = 1.0 }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .padding(.trailing)
                            .buttonStyle(.plain)
                            .help("Reset zoom")
                        }
                    }
                }
                
                
                //MARK: - TOOLS: Copy to Cliboard, Undo, Redo, Flatten, Save, Save As.
                
                ToolbarItemGroup(placement: .navigation){
                    
                    Menu {
                        
                        // Undo
                        Button(action: performUndo) {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(undoStack.isEmpty || selectedSnapURL == nil)
                        
                        // Redo
                        Button(action: performRedo) {
                            Label("Redo", systemImage: "arrow.uturn.forward")
                        }
                        .disabled(redoStack.isEmpty || selectedSnapURL == nil)
                        
                        // Flatten and Save (in place)
                        Button(action: flattenAndSaveInPlace) {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                        
                        // Flatten and Save As
                        Button(action: flattenAndSaveAs) {
                            Label("Save As", systemImage: "square.and.arrow.down.on.square")
                        }
                        
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                    } primaryAction: {
                        // Flatten & Copy to Clipboard
                        flattenRefreshAndCopy()
                        selectedTool = .pointer
                        selectedObjectID = nil
                        activeHandle = .none
                        cropDraftRect = nil
                        cropRect = nil
                        cropHandle = .none
                        focusedTextID = nil
                    }
                }
                
                // MARK: - TOOLS: Pointer, Pen, Arrow, Highlighter.
                
                ToolbarItem(id: "pointer", placement: .navigation) {
                    Button(action: { selectedTool = .pointer
                        selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                        focusedTextID = nil
                        
                    }) {
                        Label("Pointer", systemImage: "cursorarrow")
                            .foregroundStyle(selectedTool == .pointer ? Color.white : Color.primary)
                        
                    }
                    .glassEffect(selectedTool == .pointer ? .regular.tint(.blue) : .regular)
                }
                
                
                ToolbarItem(id: "pens", placement: .principal) {
                    // Pen, Arrow, Highlighter.
                    
                    Menu {
                        // Always show all three tools first
                        Button(action: {
                            selectedTool = .line
                            lineHasArrow = false
                            selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                            focusedTextID = nil
                        }) {
                            HStack {
                                Image(systemName: "pencil.line")
                                Text("Pen")
                            }
                        }
                        
                        Button(action: {
                            selectedTool = .line
                            lineHasArrow = true
                            selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                            focusedTextID = nil
                        }) {
                            HStack {
                                Image(systemName: "arrow.right")
                                Text("Arrow")
                            }
                        }
                        
                        Button(action: {
                            selectedTool = .highlighter
                            selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                            focusedTextID = nil
                        }) {
                            HStack {
                                Image(systemName: "highlighter")
                                Text("Highlighter")
                            }
                        }
                        
                        Divider()
                        
                        if selectedTool == .highlighter {
                            Section("Highlighter Color") {
                                PenColorButton(current: highlighterColorBinding, color: NSColor.systemYellow.withAlphaComponent(0.35), name: "Yellow")
                                PenColorButton(current: highlighterColorBinding, color: NSColor.systemGreen.withAlphaComponent(0.35), name: "Green")
                                PenColorButton(current: highlighterColorBinding, color: NSColor.systemBlue.withAlphaComponent(0.35), name: "Blue")
                                PenColorButton(current:highlighterColorBinding, color: NSColor.systemPink.withAlphaComponent(0.35), name: "Pink")
                            }
                        }
                        else {
                            colorButtons(current: lineColorBinding)
                        }
                        
                        Divider()
                        
                        Menu("Line Width") {
                            ForEach([1,2,3,4,6,8,12,16], id: \.self) { w in
                                Button(action: { strokeWidth = CGFloat(w) }) {
                                    if Int(strokeWidth) == w { Image(systemName: "checkmark") }
                                    Text("\(w) pt")
                                }
                            }
                        }
                        
                    } label: {
                        if selectedTool == .highlighter {
                            Label("Shapes", systemImage: "highlighter")
                                .frame(width: 200)
                                .fixedSize()
                        }
                        else if selectedTool == .line && lineHasArrow == true {
                            Label("Shapes", systemImage: "arrow.right")
                                .frame(width: 200)
                                .fixedSize()
                        }
                        else {
                            Label("Shapes", systemImage: "pencil.line")
                                .frame(width: 200)
                                .fixedSize()
                        }
                    } primaryAction: {
                        if selectedTool == .line && lineHasArrow == true {
                            selectedTool = .line
                            lineHasArrow = true
                            selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                            focusedTextID = nil
                        }
                        else if selectedTool == .highlighter {
                            selectedTool = .highlighter
                            selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                            focusedTextID = nil
                        }
                        else {
                            selectedTool = .line
                            lineHasArrow = false
                            selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                            focusedTextID = nil
                        }
                    }
                    .id("\(selectedTool)-\(lineHasArrow)-\(lineColor)")
                    .glassEffect(
                        (selectedTool == .line || selectedTool == .highlighter)
                            ? .regular.tint(
                                Color(nsColor: selectedTool == .line
                                      ? lineColor
                                      : highlighterColor
                                ).opacity(0.7)
                            )
                            : .regular
                    )

                }
                
                
                // MARK: - TOOLS - SHAPE & Increment
                
                ToolbarItemGroup(placement: .principal) {
                    // Shape rectable and oval
                    Menu {
                        Button {
                            selectedTool = .rect
                            selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                            focusedTextID = nil
                        } label: {
                            Label("Rectangle", systemImage: "square.dashed")
                        }
                        
                        Button {
                            selectedTool = .oval
                            selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                            focusedTextID = nil
                        } label: {
                            Label("Oval", systemImage: "circle.dashed")
                        }

                        
                        Divider()
                        
                        if selectedTool == .oval {
                            colorButtons(current: ovalColorBinding)
                        }
                        else {
                            colorButtons(current: rectColorBinding)
                        }
                        
                        Divider()
                        
                        Menu("Line Width") {
                            ForEach([1,2,3,4,6,8,12,16], id: \.self) { w in
                                Button(action: { strokeWidth = CGFloat(w) }) {
                                    if Int(strokeWidth) == w { Image(systemName: "checkmark") }
                                    Text("\(w) pt")
                                }
                            }
                        }
  
                    } label: {
                        if selectedTool == .oval {
                            Label("Shapes", systemImage: "circle.dashed")
                        }
                        else {
                            Label("Shapes", systemImage: "square.dashed")
                        }
                        
                    } primaryAction: {
                        selectedTool = .rect
                        selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                        focusedTextID = nil
                    }
                    .id("\(selectedTool)-\(rectColor.description)-\(ovalColor.description)")
                    .glassEffect(
                        selectedTool == .oval
                            ? .regular.tint(Color(nsColor: ovalColor).opacity(0.7))
                            : selectedTool == .rect
                                ? .regular.tint(Color(nsColor: rectColor).opacity(0.7))
                                : .regular
                    )
                    .help("Click to draw a shape")
                    
                    // Increment (badge)
                    Menu {
                        colorButtons(current: badgeColorBinding)

                        Divider()
                        
                        Button("Reset Counter") { badgeCount = 0 }
                    } label: {
                        Label("Badges", systemImage: "1.circle")
                    } primaryAction: {
                        selectedTool = .badge
                        selectedObjectID = nil
                        activeHandle = .none
                        cropDraftRect = nil
                        cropRect = nil
                        cropHandle = .none
                        focusedTextID = nil
                    }
                    .id(badgeColor)
                    .glassEffect(selectedTool == .badge ? .regular.tint(Color(nsColor: badgeColor).opacity(0.7)) : .regular)
                    .help("Click to place numbered badge")
                    
                    // Text Tool
                    Menu {
                        
                        colorButtons(current: textColorBinding)
                        
                        Divider()
                        
                        Menu("Font Size") {
                            ForEach([10,12,14,16,18,22,26,32,40,48], id: \.self) { s in
                                Button(action: { textFontSize = CGFloat(s) }) {
                                    if Int(textFontSize) == s { Image(systemName: "checkmark") }
                                    Text("\(s) pt")
                                }
                            }
                        }
                        
                        Divider()
                        
                        Toggle("Background", isOn: $textBGEnabled)
                                                
                        Menu("Background Color") {
                            PenColorButton(current: textBGColorBinding, color: .black.withAlphaComponent(0.6), name: "Black 60%")
                            PenColorButton(current: textBGColorBinding, color: NSColor.white.withAlphaComponent(0.7), name: "White 70%")
                            PenColorButton(current: textBGColorBinding, color: NSColor.red.withAlphaComponent(0.5), name: "Red 50%")
                            PenColorButton(current: textBGColorBinding, color: NSColor.blue.withAlphaComponent(0.5), name: "Blue 50%")
                            PenColorButton(current: textBGColorBinding, color: NSColor.systemGreen.withAlphaComponent(0.5), name: "Green 50%")
                            PenColorButton(current: textBGColorBinding, color: NSColor.systemYellow.withAlphaComponent(0.5), name: "Yellow 50%")
                        }
                        
                        
                    } label: {
                        Label("Text", systemImage: "textformat")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(selectedTool == .text ? Color.white : Color.primary)
                            .tint(selectedTool == .text ? .white : .primary)
                    } primaryAction: {
                        selectedTool = .text
                        selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                    }
                    .id(textColor)
                    .id(textBGEnabled)
                    .id(textBGColor)
                    .id(textFontSize)
                    .glassEffect(selectedTool == .text ? .regular.tint(Color(nsColor: textColor).opacity(0.7)) : .regular)
                    .help("Click to place a text box.")
                    
                    // Crop
                    Button(action: {
                        selectedTool = .crop
                        selectedObjectID = nil
                        activeHandle = .none
                        focusedTextID = nil
                        
                    }) {
                        Label("Crop", systemImage: "crop")
                            .foregroundStyle(selectedTool == .crop ? Color.white : Color.primary)
                    }
                    .glassEffect(selectedTool == .crop ? .regular.tint(.blue) : .regular)
                    .help("Drag to select an area to crop")
                    
                }
            }        else {
                ToolbarItem(placement: .principal) {
                    Spacer()
                }
            }
            
            // Capture Region button (always available)
            ToolbarItem(placement: .primaryAction) {
                Button(action: startSelection) {
                    Label("Capture Region", systemImage: "camera.viewfinder")
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { activeImporter != nil },
                set: { if $0 == false { activeImporter = nil } }
            ),
            allowedContentTypes: (activeImporter == .folder) ? [.folder] : [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if url.hasDirectoryPath {
                    // Folder chosen
                    DispatchQueue.main.async {
                        saveDirectoryPath = url.path
                        loadExistingSnaps()
                    }
                } else {
                    // Image chosen
                    DispatchQueue.main.async {
                        undoStack.removeAll()
                        redoStack.removeAll()
                        selectedSnapURL = url
                        selectedImageSize = probeImageSize(url)
                        lastFittedSize = nil
                        objects.removeAll()
                        objectSpaceSize = nil
                        selectedObjectID = nil
                        activeHandle = .none
                        cropRect = nil
                        cropDraftRect = nil
                        cropHandle = .none
                        updateMenuState()
                        if let dir = snapsDirectory(), url.path.hasPrefix(dir.path) {
                            insertSnapURL(url)
                        }
                    }
                }
            case .failure(let error):
                print("Selection canceled/failed: \(error)")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func updateMenuState() {
        MenuState.shared.canUndo = !undoStack.isEmpty
        MenuState.shared.canRedo = !redoStack.isEmpty
        MenuState.shared.hasSelectedImage = selectedSnapURL != nil
    }
    
    private func reloadCurrentImage() {
        guard let url = selectedSnapURL else { return }
        
        // Force AsyncImage to reload by changing the trigger
        imageReloadTrigger = UUID()
        
        // Update the image size in case it changed during flattening
        selectedImageSize = probeImageSize(url)
        
        // Reset fitted size so it recalculates
        lastFittedSize = nil
        print("RELOAD!")
    }
    
    private func fittedRectToAuthorRect(_ rect: CGRect, fitted: CGSize, author: CGSize) -> CGRect {
        let sx = author.width / max(1, fitted.width)
        let sy = author.height / max(1, fitted.height)
        return CGRect(
            x: rect.origin.x * sx,
            y: rect.origin.y * sy,
            width: rect.width * sx,
            height: rect.height * sy
        )
    }

    /// Double-click / double-tap to toggle zoom using existing zoom slider values.
    /// - Note: Only active when imageDisplayMode is not "fit".
    private func handleDoubleTapZoom() {
        guard imageDisplayMode != "fit" else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            if zoomLevel < 1.5 {
                // Jump to a comfortable zoom-in step that matches the slider's range.
                zoomLevel = 2.0
            } else {
                // Return to 1x for a quick reset
                zoomLevel = 1.0
            }
        }
    }
    
    /// Probe image dimensions without instantiating NSImage (low RAM)
    private func probeImageSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth]  as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return (w > 0 && h > 0) ? CGSize(width: w, height: h) : nil
    }

    /// Returns the pixel dimensions of an NSImage by inspecting its best bitmap representation.
    private func pixelSize(of image: NSImage) -> CGSize {
        if let bestRep = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return CGSize(width: bestRep.pixelsWide, height: bestRep.pixelsHigh)
        }
        return CGSize(width: image.size.width, height: image.size.height)
    }

    /// Map a rect in the *fitted/UI* coordinate space directly into *image pixel* space (bottom-left origin).
    /// - Parameters:
    ///   - crpRect: Rect drawn in fitted-space (top-left origin inside SwiftUI, but our math uses sizes so origin is fine).
    ///   - fitted: The size of the fitted image as shown in the UI.
    ///   - imagePx: The pixel size of the underlying image (CGImage/bitmap rep).
    private func fittedRectToImageBottomLeftRect(crpRect: CGRect, fitted: CGSize, imagePx: CGSize) -> CGRect {
        let sx = imagePx.width / max(1, fitted.width)
        let sy = imagePx.height / max(1, fitted.height)

        let x = crpRect.origin.x * sx
        let w = crpRect.size.width * sx

        // Convert to bottom-left: y_bl = H - (y_top + h)
        let yTop = crpRect.origin.y * sy
        let h = crpRect.size.height * sy
        let yBL = imagePx.height - (yTop + h)

        // Clamp to image bounds to avoid tiny rounding issues
        let clamped = CGRect(x: max(0, x).rounded(.down),
                             y: max(0, yBL).rounded(.down),
                             width: min(w, imagePx.width - max(0, x)).rounded(.down),
                             height: min(h, imagePx.height - max(0, yBL)).rounded(.down))
        return clamped
    }
    
    
    func colorButtons(current: Binding<NSColor>) -> some View {
        let availableColors = ["red", "blue", "green", "yellow", "black", "white", "orange", "purple", "pink", "gray"]
        
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(availableColors, id: \.self) { colorName in
                colorButton(current: current, colorName: colorName)
            }
        }
    }
    
    func colorsEqual(_ a: NSColor, _ b: NSColor, tol: CGFloat = 0.001) -> Bool {
        // Prefer sRGB; fall back to deviceRGB; finally fall back to NSObject equality.
        if let ar = a.usingColorSpace(.sRGB), let br = b.usingColorSpace(.sRGB) {
            return abs(ar.redComponent   - br.redComponent)   < tol &&
                   abs(ar.greenComponent - br.greenComponent) < tol &&
                   abs(ar.blueComponent  - br.blueComponent)  < tol &&
                   abs(ar.alphaComponent - br.alphaComponent) < tol
        }
        if let ar = a.usingColorSpace(.deviceRGB), let br = b.usingColorSpace(.deviceRGB) {
            return abs(ar.redComponent   - br.redComponent)   < tol &&
                   abs(ar.greenComponent - br.greenComponent) < tol &&
                   abs(ar.blueComponent  - br.blueComponent)  < tol &&
                   abs(ar.alphaComponent - br.alphaComponent) < tol
        }
        return a.isEqual(b)
    }
    
    func colorButton(current: Binding<NSColor>, colorName: String) -> some View {
        // Map string to NSColor
        let color: NSColor = {
            switch colorName.lowercased() {
            case "red":    .systemRed
            case "blue":   .systemBlue
            case "green":  .systemGreen
            case "yellow": .systemYellow
            case "black":  .black
            case "white":  .white
            case "orange": .systemOrange
            case "purple": .systemPurple
            case "pink":   .systemPink
            case "gray", "grey": .systemGray
            default:       .black
            }
        }()

        let displayName = colorName.prefix(1).uppercased() + colorName.dropFirst().lowercased()
        let isSelected = colorsEqual(current.wrappedValue, color)

        return Button(action: { current.wrappedValue = color }) {
            HStack {
                Image(systemName: isSelected ? "checkmark" : "circle.fill")
                    .foregroundStyle(Color(nsColor: color), .primary, .secondary)
                Text(displayName)
            }
        }
    }
    
    // Centralized tool switching used by menu notifications
    private func handleSelectTool(_ raw: String) {
        switch raw {
        case "pointer":
            selectedTool = .pointer
        case "pen":
            lineHasArrow = false
            selectedTool = .line
            selectedObjectID = nil
            activeHandle = .none
            cropDraftRect = nil
            cropRect = nil
            cropHandle = .none
            focusedTextID = nil
        case "arrow":
            selectedTool = .line
            lineHasArrow = true
            selectedObjectID = nil
            activeHandle = .none
            cropDraftRect = nil
            cropRect = nil
            cropHandle = .none
            focusedTextID = nil
        case "highlighter": selectedTool = .highlighter
        case "rect":       selectedTool = .rect
        case "oval":        selectedTool = .oval
        case "increment":   selectedTool = .badge
        case "text":        selectedTool = .text
        case "crop":        selectedTool = .crop
        default: break
        }
    }
    
    // Settings - Downsample from Retina
    private func isRetinaImage(_ image: NSImage) -> Bool {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return false }
        
        let pointSize = image.size
        let pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        
        let scaleX = pixelSize.width / pointSize.width
        let scaleY = pixelSize.height / pointSize.height
        
        return scaleX > 1.5 || scaleY > 1.5
    }
    
    private func downsampleImage(_ image: NSImage) -> NSImage {
        let pointSize = image.size
        
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(pointSize.width),
                                   pixelsHigh: Int(pointSize.height),
                                   bitsPerSample: 8,
                                   samplesPerPixel: 4,
                                   hasAlpha: true,
                                   isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0,
                                   bitsPerPixel: 0)
        
        guard let rep = rep else { return image }
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: pointSize))
        NSGraphicsContext.restoreGraphicsState()
        
        let downsampledImage = NSImage(size: pointSize)
        downsampledImage.addRepresentation(rep)
        return downsampledImage
    }
    

    
    private func cropHandleHitTest(_ rect: CGRect, at p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }
    
    private func resizeRect(_ rect: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var c = rect
        switch handle {
        case .rectTopLeft:
            c = CGRect(x: p.x, y: p.y, width: rect.maxX - p.x, height: rect.maxY - p.y)
        case .rectTopRight:
            c = CGRect(x: rect.minX, y: p.y, width: p.x - rect.minX, height: rect.maxY - p.y)
        case .rectBottomLeft:
            c = CGRect(x: p.x, y: rect.minY, width: rect.maxX - p.x, height: p.y - rect.minY)
        case .rectBottomRight:
            c = CGRect(x: rect.minX, y: rect.minY, width: p.x - rect.minX, height: p.y - rect.minY)
        default:
            break
        }
        // Minimum size
        c.size.width = max(2, c.size.width)
        c.size.height = max(2, c.size.height)
        return c
    }
    
    private func startSelection() {
        WindowManager.shared.closeAllAppWindows()
        
        SelectionWindowManager.shared.present(onComplete: { rect in
            Task {
                // Use the same capture method as the hotkey to avoid duplication
                if let img = await GlobalHotKeyManager.shared.captureScreenshot(rect: rect) {
                    if let savedURL = ImageSaver.saveImage(img, to: snapsDirectory()) {
                        DispatchQueue.main.async {
                            // Handle the ContentView-specific cleanup that was in saveSnapToDisk
                            self.insertSnapURL(savedURL)  // Add to gallery
                            
                            // Clear any retained image references
                            self.selectedImageSize = nil
                            // Limit undo stack growth
                            if self.undoStack.count > 5 { self.undoStack.removeFirst(self.undoStack.count - 5) }
                            if self.redoStack.count > 5 { self.redoStack.removeFirst(self.redoStack.count - 5) }
                            
                            WindowManager.shared.loadImageIntoWindow(url: savedURL, shouldActivate: true)
                        }
                    }
                    // img goes out of scope and gets deallocated immediately
                }
            }
        })
    }
    
    private func endSelectionCleanup() {
        SelectionWindowManager.shared.dismiss()
    }
    
    /// Captures a screenshot of the selected rect using ScreenCaptureKit, selecting the correct display.
    private func captureAsync(rect selectedGlobalRect: CGRect) async -> NSImage? {
        defer { endSelectionCleanup() }
        
        guard let bestScreen = bestScreenForSelection(selectedGlobalRect) else { return nil }
        let screenFramePts = bestScreen.frame
        let intersectPts = selectedGlobalRect.intersection(screenFramePts)
        if intersectPts.isNull || intersectPts.isEmpty { return nil }
        
        guard let cgIDNum = bestScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let cgID = CGDirectDisplayID(truncating: cgIDNum)
        
        do {
            let content = try await SCShareableContent.current
            guard let scDisplay = content.displays.first(where: { $0.displayID == cgID }) else { return nil }
            
            let scale = bestScreen.backingScaleFactor
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            
            // CRITICAL: Capture and process immediately
            guard let fullCG = await ScreenCapturer.shared.captureImage(using: filter, display: scDisplay) else { return nil }
            
            let cropPx = cropRectPixels(intersectPts,
                                        withinScreenFramePts: screenFramePts,
                                        imageSizePx: CGSize(width: fullCG.width, height: fullCG.height),
                                        scaleX: scale, scaleY: scale)
            
            let clamped = CGRect(x: max(0, cropPx.origin.x),
                                 y: max(0, cropPx.origin.y),
                                 width: min(cropPx.width, CGFloat(fullCG.width) - max(0, cropPx.origin.x)),
                                 height: min(cropPx.height, CGFloat(fullCG.height) - max(0, cropPx.origin.y)))
            
            guard clamped.width > 1, clamped.height > 1,
                  let cropped = fullCG.cropping(to: clamped) else { return nil }
            
            // Create final image and return immediately
            let pointSize = CGSize(width: CGFloat(cropped.width) / scale,
                                   height: CGFloat(cropped.height) / scale)
            
            let rep = NSBitmapImageRep(cgImage: cropped)
            rep.size = pointSize
            
            let result = NSImage(size: pointSize)
            result.addRepresentation(rep)
            return result
            // fullCG, cropped, and rep all deallocate here
            
        } catch {
            return nil
        }
    }
    /// Returns the screen with the largest intersection area with the selection.
    private func bestScreenForSelection(_ selection: CGRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for s in NSScreen.screens {
            let a = selection.intersection(s.frame).area
            if a > (best?.area ?? 0) { best = (s, a) }
        }
        return best?.screen
    }
    
    /// Convert a selection rect in **points** (global screen coords) to a **pixel** crop rect with origin at top-left of the display image.
    private func cropRectPixels(_ selectionPts: CGRect, withinScreenFramePts screenPts: CGRect, imageSizePx: CGSize, scaleX: CGFloat, scaleY: CGFloat) -> CGRect {
        // Translate selection to screen-local origin (points)
        let localXPts = selectionPts.origin.x - screenPts.origin.x
        let localYPts = selectionPts.origin.y - screenPts.origin.y
        // Pixel sizes using per-axis scales (accounts for non-integer scaling / "More Space")
        let widthPx  = selectionPts.size.width * scaleX
        let heightPx = selectionPts.size.height * scaleY
        let xPx = localXPts * scaleX
        // CGImage crop rect uses TOP-LEFT origin; convert from bottom-left screen coords
        let yPx = imageSizePx.height - (localYPts * scaleY + heightPx)
        return CGRect(x: xPx.rounded(.down), y: yPx.rounded(.down), width: widthPx.rounded(.down), height: heightPx.rounded(.down))
    }
    

    private func copyToPasteboard(_ image: NSImage) {
        // 1) ALWAYS flatten first so annotations are included
        let flattened: NSImage = {
            if let f = rasterize(base: image, objects: objects) { return f }
            return image // graceful fallback
        }()

        // 2) Respect user toggle: only downsample if requested AND the image is retina
        let shouldDownsample = downsampleToNonRetinaClipboard && isRetinaImage(flattened)
        let source: NSImage = shouldDownsample ? downsampleImage(flattened) : flattened

        // 3) Put pixel-accurate PNG bytes on the pasteboard to avoid implicit 1x collapse
        let pb = NSPasteboard.general
        pb.clearContents()

        // Prefer the backing bitmap rep's CGImage to avoid collapsing to 1x
        let bestRep = source.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })

        if let cg = bestRep?.cgImage ?? source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cg)
            if let data = rep.representation(using: .png, properties: [:]) {
                pb.setData(data, forType: .png)
            } else {
                pb.writeObjects([source])
            }
        } else {
            pb.writeObjects([source])
        }

        // 4) Optional: Save the rasterized image to disk when enabled in settings (non-destructive)
        if UserDefaults.standard.bool(forKey: "saveOnCopy") {
            if let url = selectedSnapURL {
                if ImageSaver.writeImage(source, to: url, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                    refreshGalleryAfterSaving(to: url)
                    reloadCurrentImage()
                    
                    // NEW: Clear all drawn objects after successful save
                    objects.removeAll()
                    selectedObjectID = nil
                    activeHandle = .none
                    focusedTextID = nil
                    cropRect = nil
                    cropDraftRect = nil
                    cropHandle = .none
                }
            } else if let dir = snapsDirectory() {
                let newName = ImageSaver.generateFilename(for: preferredSaveFormat.rawValue)
                let dest = dir.appendingPathComponent(newName)
                if ImageSaver.writeImage(source, to: dest, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                    selectedSnapURL = dest
                    refreshGalleryAfterSaving(to: dest)
                    reloadCurrentImage()
                    
                    // NEW: Clear all drawn objects after successful save
                    objects.removeAll()
                    selectedObjectID = nil
                    activeHandle = .none
                    focusedTextID = nil
                    cropRect = nil
                    cropDraftRect = nil
                    cropHandle = .none
                }
            } else {
                // Fallback if no directory available
                saveAsCurrent()
                
                // NEW: Clear objects after saveAsCurrent completes successfully
                // Note: You might want to modify saveAsCurrent to return a Bool indicating success
                objects.removeAll()
                selectedObjectID = nil
                activeHandle = .none
                focusedTextID = nil
                cropRect = nil
                cropDraftRect = nil
                cropHandle = .none
            }
        }

        withAnimation { showCopiedHUD = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { showCopiedHUD = false }
        }
    }
    /// Flattens the current canvas into the image, refreshes state, then copies the latest to the clipboard.
    private func flattenRefreshAndCopy() {
        // 1) Flatten into currentImage (and save) using existing logic
        //flattenAndSaveInPlace()
        // 2) On the next run loop, copy the refreshed image so we don't grab stale state
        DispatchQueue.main.async {
            if let current = self.currentImage {
                self.copyToPasteboard(current)
            }
        }
    }
    
    private func pushUndoSnapshot() {
        undoStack.append(Snapshot(imageURL: selectedSnapURL, objects: objects))
        // Limit for 24/7 operation
        while undoStack.count > 3 { undoStack.removeFirst() }
        redoStack.removeAll()
        
        updateMenuState()
        
    }
    
    // MARK: - Save / Save As
    
    /// Save As… — prompts for a destination, updates gallery if under snaps folder.
    private func saveAsCurrent() {
        guard let img = currentImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [preferredSaveFormat.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if !saveDirectoryPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        }
        if let sel = selectedSnapURL {
            panel.directoryURL = sel.deletingLastPathComponent()
            panel.nameFieldStringValue = sel.lastPathComponent
        } else if let dir = snapsDirectory() {
            panel.directoryURL = dir
            panel.nameFieldStringValue = ImageSaver.generateFilename(for: preferredSaveFormat.rawValue)
        } else {
            panel.nameFieldStringValue = ImageSaver.generateFilename(for: preferredSaveFormat.rawValue)
        }
        if panel.runModal() == .OK, let url = panel.url {
            if ImageSaver.writeImage(img, to: url, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                selectedSnapURL = url
                refreshGalleryAfterSaving(to: url)
                reloadCurrentImage()
            }
        }
    }
    
    /// If saved file is within our snaps directory, update the gallery list.
    private func refreshGalleryAfterSaving(to url: URL) {
        if let dir = snapsDirectory(), url.path.hasPrefix(dir.path) {
            insertSnapURL(url)
        }
        
        // Refresh thumbnails.
        thumbnailRefreshTrigger = UUID()
        
    }
    
    
    private func lineGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let currentFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let start = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                var current = fittedToAuthorPoint(currentFit, fitted: fitted, author: author)
                let shift = NSEvent.modifierFlags.contains(.shift)
                if shift { current = snappedPoint(start: start, raw: current) }

                if dragStartPoint == nil {
                    dragStartPoint = start
                    // Start over an existing line? select + figure out which endpoint (if any) we grabbed
                    if let idx = objects.lastIndex(where: { obj in
                        switch obj {
                        case .line(let o): return o.handleHitTest(start) != .none || o.hitTest(start)
                        default: return false
                        }
                    }) {
                        selectedObjectID = objects[idx].id
                        if case .line(let o) = objects[idx] { activeHandle = o.handleHitTest(start) }
                    } else {
                        selectedObjectID = nil
                        activeHandle = .none
                    }
                } else if
                    let sel = selectedObjectID,
                    let s = dragStartPoint,
                    let idx = objects.firstIndex(where: { $0.id == sel })
                {
                    // Move whole line or resize one endpoint
                    let delta = CGSize(width: current.x - s.x, height: current.y - s.y)
                    let dragDistance = hypot(delta.width, delta.height)
                    if dragDistance > 0.5 {
                        if !pushedDragUndo { pushUndoSnapshot(); pushedDragUndo = true }
                        switch objects[idx] {
                        case .line(let o):
                            var updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: current)
                            updated.start = clampPoint(updated.start, in: author)
                            updated.end   = clampPoint(updated.end,   in: author)
                            objects[idx] = .line(updated)
                        default:
                            break
                        }
                        dragStartPoint = current
                    }
                } else {
                    // Use `draft` for live line preview
                    draft = Line(start: start, end: current, width: strokeWidth)
                }
            }
            .onEnded { value in
                let endFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                var end = fittedToAuthorPoint(endFit, fitted: fitted, author: author)
                if NSEvent.modifierFlags.contains(.shift), let s = dragStartPoint {
                    end = snappedPoint(start: s, raw: end)
                }

                defer { dragStartPoint = nil; pushedDragUndo = false; activeHandle = .none; draft = nil; draftRect = nil }

                // Finished moving/resizing an existing line
                if let _ = selectedObjectID,
                   let idx = objects.firstIndex(where: { $0.id == selectedObjectID }),
                   case .line = objects[idx] {
                    return
                }

                // Create new line from the live draft if present, else from start/end
                if let d = draft {
                    let new = LineObject(start: d.start, end: d.end, width: d.width, arrow: lineHasArrow, color: lineColor)
                    pushUndoSnapshot()
                    objects.append(.line(new))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = new.id
                } else if let s = dragStartPoint {
                    let new = LineObject(start: s, end: end, width: strokeWidth, arrow: lineHasArrow, color: lineColor)
                    pushUndoSnapshot()
                    objects.append(.line(new))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = new.id
                }
            }
    }
    
    private func rectGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let currentFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let start = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                let current = fittedToAuthorPoint(currentFit, fitted: fitted, author: author)
                let shift = NSEvent.modifierFlags.contains(.shift)

                if dragStartPoint == nil {
                    dragStartPoint = start
                    // If starting on an existing rect, select it and capture which handle (if any)
                    if let idx = objects.lastIndex(where: { obj in
                        switch obj {
                        case .rect(let o): return o.handleHitTest(start) != .none || o.hitTest(start)
                        default: return false
                        }
                    }) {
                        selectedObjectID = objects[idx].id
                        if case .rect(let o) = objects[idx] { activeHandle = o.handleHitTest(start) }
                    } else {
                        selectedObjectID = nil
                        activeHandle = .none
                    }
                } else if
                    let sel = selectedObjectID,
                    let s = dragStartPoint,
                    let idx = objects.firstIndex(where: { $0.id == sel })
                {
                    // We are interacting with an existing rectangle: move or resize
                    let delta = CGSize(width: current.x - s.x, height: current.y - s.y)
                    let dragDistance = hypot(delta.width, delta.height)
                    if dragDistance > 0.5 {
                        if !pushedDragUndo { pushUndoSnapshot(); pushedDragUndo = true }
                        switch objects[idx] {
                        case .rect(let o):
                            let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: current)
                            let clamped = clampRect(updated.rect, in: author)
                            var u = updated; u.rect = clamped
                            objects[idx] = .rect(u)
                        default:
                            break
                        }
                        dragStartPoint = current
                    }
                } else {
                    // No selection: show a draft for creating a new rectangle (Shift = square)
                    func rectFrom(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
                        var x0 = min(a.x, b.x)
                        var y0 = min(a.y, b.y)
                        var w = abs(a.x - b.x)
                        var h = abs(a.y - b.y)
                        if square {
                            let side = max(w, h)
                            x0 = (b.x >= a.x) ? a.x : (a.x - side)
                            y0 = (b.y >= a.y) ? a.y : (a.y - side)
                            w = side; h = side
                        }
                        return CGRect(x: x0, y: y0, width: w, height: h)
                    }
                    draftRect = rectFrom(start, current, square: shift)
                }
            }
            .onEnded { value in
                let endFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let pEnd = fittedToAuthorPoint(endFit, fitted: fitted, author: author)

                defer { dragStartPoint = nil; pushedDragUndo = false; activeHandle = .none; draftRect = nil }

                // If we were moving/resizing an existing rect, we're done
                if let _ = selectedObjectID,
                   let idx = objects.firstIndex(where: { $0.id == selectedObjectID }) {
                    if case .rect = objects[idx] {
                        return
                    }
                }

                // Create a new rectangle from the draft drag area if present…
                if let r = draftRect {
                    let clamped = clampRect(r, in: author)
                    let newObj = RectObject(rect: clamped, width: strokeWidth, color: rectColor)  // Pass current color
                    pushUndoSnapshot()
                    objects.append(.rect(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                } else {
                    // on simple click with no drag, create a default-sized square
                    let d: CGFloat = 40
                    let rect = CGRect(x: max(0, pEnd.x - d/2), y: max(0, pEnd.y - d/2), width: d, height: d)
                    let clamped = clampRect(rect, in: author)
                    let newObj = RectObject(rect: clamped, width: strokeWidth, color: rectColor)  // Pass current color
                    pushUndoSnapshot()
                    objects.append(.rect(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                }
            }
    }
    
    private func ovalGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let currentFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let start = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                let current = fittedToAuthorPoint(currentFit, fitted: fitted, author: author)

                if dragStartPoint == nil {
                    dragStartPoint = start
                    if let idx = objects.lastIndex(where: { obj in
                        switch obj {
                        case .oval(let o): return o.handleHitTest(start) != .none || o.hitTest(start)
                        default: return false
                        }
                    }) {
                        selectedObjectID = objects[idx].id
                        if case .oval(let o) = objects[idx] { activeHandle = o.handleHitTest(start) }
                    } else {
                        selectedObjectID = nil
                        activeHandle = .none
                    }
                } else if
                    let sel = selectedObjectID,
                    let s = dragStartPoint,
                    let idx = objects.firstIndex(where: { $0.id == sel })
                {
                    let delta = CGSize(width: current.x - s.x, height: current.y - s.y)
                    let dragDistance = hypot(delta.width, delta.height)
                    if dragDistance > 0.5 {
                        if !pushedDragUndo { pushUndoSnapshot(); pushedDragUndo = true }
                        switch objects[idx] {
                        case .oval(var o):
                            let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: current)
                            let clamped = clampRect(updated.rect, in: author)
                            o.rect = clamped
                            objects[idx] = .oval(o)
                        default:
                            break
                        }
                        dragStartPoint = current
                    }
                } else {
                    // show draft rect while dragging a new oval
                    let x0 = min(start.x, current.x)
                    let y0 = min(start.y, current.y)
                    let w = abs(start.x - current.x)
                    let h = abs(start.y - current.y)
                    draftRect = CGRect(x: x0, y: y0, width: w, height: h)
                }
            }
            .onEnded { value in
                let endFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let pEnd = fittedToAuthorPoint(endFit, fitted: fitted, author: author)

                defer { dragStartPoint = nil; pushedDragUndo = false; activeHandle = .none; draftRect = nil }

                if let _ = selectedObjectID { return } // finished move/resize

                if let r = draftRect {
                    let clamped = clampRect(r, in: author)
                    let newObj = OvalObject(rect: clamped, width: strokeWidth, color: ovalColor)  // Pass current color
                    pushUndoSnapshot()
                    objects.append(.oval(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                } else {
                    let d: CGFloat = 40
                    let rect = CGRect(x: max(0, pEnd.x - d/2), y: max(0, pEnd.y - d/2), width: d, height: d)
                    let clamped = clampRect(rect, in: author)
                    let newObj = OvalObject(rect: clamped, width: strokeWidth, color: ovalColor)  // Pass current color
                    pushUndoSnapshot()
                    objects.append(.oval(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                }
            }
    }
    
    private func highlightGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }

                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let currentFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let start = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                let current = fittedToAuthorPoint(currentFit, fitted: fitted, author: author)

                if dragStartPoint == nil {
                    dragStartPoint = start
                    // If starting on an existing highlight, select it and capture handle (if any)
                    if let idx = objects.lastIndex(where: { obj in
                        switch obj {
                        case .highlight(let o): return o.handleHitTest(start) != .none || o.hitTest(start)
                        default: return false
                        }
                    }) {
                        selectedObjectID = objects[idx].id
                        if case .highlight(let o) = objects[idx] { activeHandle = o.handleHitTest(start) }
                    } else {
                        selectedObjectID = nil
                        activeHandle = .none
                    }
                } else if
                    let sel = selectedObjectID,
                    let s = dragStartPoint,
                    let idx = objects.firstIndex(where: { $0.id == sel })
                {
                    // Move or resize existing highlight
                    let delta = CGSize(width: current.x - s.x, height: current.y - s.y)
                    let dragDistance = hypot(delta.width, delta.height)
                    if dragDistance > 0.5 {
                        if !pushedDragUndo { pushUndoSnapshot(); pushedDragUndo = true }
                        switch objects[idx] {
                        case .highlight(let o):
                            let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: current)
                            let clamped = clampRect(updated.rect, in: author)
                            var u = updated; u.rect = clamped
                            objects[idx] = .highlight(u)
                        default:
                            break
                        }
                        dragStartPoint = current
                    }
                } else {
                    // No selection: live draft (filled) while creating a new highlight
                    let x0 = min(start.x, current.x)
                    let y0 = min(start.y, current.y)
                    let w = abs(start.x - current.x)
                    let h = abs(start.y - current.y)
                    draftRect = CGRect(x: x0, y: y0, width: w, height: h)
                }
            }
            .onEnded { value in
                let endFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                _ = fittedToAuthorPoint(endFit, fitted: fitted, author: author) // not used directly

                defer { dragStartPoint = nil; pushedDragUndo = false; activeHandle = .none; draftRect = nil }

                // If we were moving/resizing an existing highlight, we're done
                if let _ = selectedObjectID,
                   let idx = objects.firstIndex(where: { $0.id == selectedObjectID }),
                   case .highlight = objects[idx] {
                    return
                }

                // Otherwise create a new highlight from the draft
                if let r = draftRect {
                    let clamped = clampRect(r, in: author)
                    let newObj = HighlightObject(rect: clamped, color: highlighterColor)
                    pushUndoSnapshot()
                    objects.append(.highlight(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                } else {
                    // Click without drag → drop a small highlight
                    let d: CGFloat = 40
                    let center = dragStartPoint ?? .zero
                    let rect = CGRect(x: max(0, center.x - d/2), y: max(0, center.y - d/2), width: d, height: d)
                    let clamped = clampRect(rect, in: author)
                    let newObj = HighlightObject(rect: clamped, color: highlighterColor)
                    pushUndoSnapshot()
                    objects.append(.highlight(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                }
            }
    }
    
    private func textGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let pFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let p = fittedToAuthorPoint(pFit, fitted: fitted, author: author)
                
                if dragStartPoint == nil {
                    dragStartPoint = p
                    // If starting on a text object, select it and decide handle
                    if let idx = objects.lastIndex(where: { obj in
                        switch obj {
                        case .text(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        default: return false
                        }
                    }) {
                        selectedObjectID = objects[idx].id
                        if case .text(let o) = objects[idx] {
                            activeHandle = o.handleHitTest(p)
                        } else {
                            activeHandle = .none
                        }
                        // Don't clear focus immediately - wait to see if this is a drag or click
                    } else {
                        selectedObjectID = nil
                        activeHandle = .none
                        focusedTextID = nil
                        
                    }
                } else if
                    let sel = selectedObjectID,
                    let start = dragStartPoint,
                    let idx = objects.firstIndex(where: { $0.id == sel })
                {
                    let delta = CGSize(width: p.x - start.x, height: p.y - start.y)
                    let dragDistance = hypot(delta.width, delta.height)
                    
                    // Only start actual dragging if we've moved a reasonable distance
                    if dragDistance > 5 {
                        // Now we know it's a drag - clear focus to prevent editing during drag
                        focusedTextID = nil
                        
                        
                        if !pushedDragUndo {
                            pushUndoSnapshot()
                            pushedDragUndo = true
                        }
                        switch objects[idx] {
                        case .text(let o):
                            let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                            let clamped = clampRect(updated.rect, in: author)
                            var u = updated; u.rect = clamped
                            objects[idx] = .text(u)
                        default:
                            break
                        }
                        dragStartPoint = p
                    }
                }
            }
            .onEnded { value in
                // Convert end & start to author space
                let endFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let pEnd = fittedToAuthorPoint(endFit, fitted: fitted, author: author)
                let pStart = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                
                let dx = pEnd.x - pStart.x
                let dy = pEnd.y - pStart.y
                let moved = hypot(dx, dy) > 5 // threshold in author space
                
                if moved {
                    // We were dragging – finish and clean up
                    dragStartPoint = nil
                    pushedDragUndo = false
                    return
                }
                
                // CLICK (or DOUBLE-CLICK) PATH:
                dragStartPoint = nil
                pushedDragUndo = false
                
                // Check for double-click first, before other click handling
                let isDoubleClick = if let event = NSApp.currentEvent {
                    event.clickCount >= 2
                } else {
                    false
                }
                
                // 1) If click is on an existing TEXT object
                if let idx = objects.lastIndex(where: { obj in
                    switch obj {
                    case .text(let o): return o.handleHitTest(pEnd) != .none || o.hitTest(pEnd)
                    default: return false
                    }
                }) {
                    selectedObjectID = objects[idx].id
                    activeHandle = .none
                    
                    if isDoubleClick {
                        // Double-click: enter edit mode
                        focusedTextID = objects[idx].id
                    } else {
                        // Single click: just select, don't edit
                        focusedTextID = nil
                        
                    }
                    return
                }
                
                // 2) Create new text box only on single click in empty space
                if !isDoubleClick {
                    let defaultSize = CGSize(width: 240, height: 80)
                    let rect = CGRect(x: max(0, pEnd.x - defaultSize.width/2),
                                      y: max(0, pEnd.y - defaultSize.height/2),
                                      width: defaultSize.width,
                                      height: defaultSize.height)
                    let rectClamped = clampRect(rect, in: author)
                    let newObj = TextObject(rect: rectClamped,
                                            text: "Text",
                                            fontSize: textFontSize,
                                            textColor: textColor,
                                            bgEnabled: textBGEnabled,
                                            bgColor: textBGColor)
                    pushUndoSnapshot()
                    objects.append(.text(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                    activeHandle = .none
                    focusedTextID = nil
                    
                    // Auto-switch to Pointer after placing a text box
                    selectedTool = .pointer
                }
            }
    }
    
    private func pointerGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let pFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let p = fittedToAuthorPoint(pFit, fitted: fitted, author: author)
                if dragStartPoint == nil {
                    dragStartPoint = p
                    if let idx = objects.firstIndex(where: { obj in
                        switch obj {
                        case .line(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .rect(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .oval(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .text(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .badge(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .highlight(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .image(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        }
                    }) {
                        selectedObjectID = objects[idx].id
                        switch objects[idx] {
                        case .line(let o): activeHandle = o.handleHitTest(p)
                        case .rect(let o): activeHandle = o.handleHitTest(p)
                        case .oval(let o): activeHandle = o.handleHitTest(p)
                        case .text(let o): activeHandle = o.handleHitTest(p)
                        case .badge(let o): activeHandle = o.handleHitTest(p)
                        case .highlight(let o): activeHandle = o.handleHitTest(p)
                        case .image(let o): activeHandle = o.handleHitTest(p)
                        }
                        // On single click or drag, always clear focus (do not enter edit mode)
                        focusedTextID = nil
                        
                    } else {
                        selectedObjectID = nil
                        activeHandle = .none
                        focusedTextID = nil
                        
                    }
                } else if let sel = selectedObjectID, let start = dragStartPoint, let idx = objects.firstIndex(where: { $0.id == sel }) {
                    let delta = CGSize(width: p.x - start.x, height: p.y - start.y)
                    if !pushedDragUndo {
                        pushUndoSnapshot()
                        pushedDragUndo = true
                    }
                    switch objects[idx] {
                    case .line(let o):
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                        var u = updated
                        u.start = clampPoint(u.start, in: author)
                        u.end   = clampPoint(u.end,   in: author)
                        objects[idx] = .line(u)
                    case .rect(let o):
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .rect(u)
                    case .oval(let o):
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .oval(u)
                    case .text(let o):
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .text(u)
                    case .badge(let o):
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .badge(u)
                    case .highlight(let o):
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .highlight(u)
                    case .image(let o):
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .image(u)
                    }
                    dragStartPoint = p
                }
            }
            .onEnded { value in  // Add 'value in' parameter here
                let endFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let pEnd = fittedToAuthorPoint(endFit, fitted: fitted, author: author)
                let pStart = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                
                let dx = pEnd.x - pStart.x
                let dy = pEnd.y - pStart.y
                let moved = hypot(dx, dy) > 5

                dragStartPoint = nil
                pushedDragUndo = false
            }
    }
    
    private func badgeGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let pFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let p = fittedToAuthorPoint(pFit, fitted: fitted, author: author)
                
                if dragStartPoint == nil {
                    dragStartPoint = p
                    // If starting on a badge, select it and decide handle (resize vs move)
                    if let idx = objects.lastIndex(where: { obj in
                        switch obj {
                        case .badge(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        default: return false
                        }
                    }) {
                        selectedObjectID = objects[idx].id
                        if case .badge(let o) = objects[idx] { activeHandle = o.handleHitTest(p) }
                    } else {
                        selectedObjectID = nil
                        activeHandle = .none
                    }
                } else if
                    let sel = selectedObjectID,
                    let start = dragStartPoint,
                    let idx = objects.firstIndex(where: { $0.id == sel })
                {
                    let delta = CGSize(width: p.x - start.x, height: p.y - start.y)
                    let dragDistance = hypot(delta.width, delta.height)
                    
                    if dragDistance > 0.5 { // any movement begins interaction
                        if !pushedDragUndo { pushUndoSnapshot(); pushedDragUndo = true }
                        switch objects[idx] {
                        case .badge(let o):
                            let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                            let clamped = clampRect(updated.rect, in: author)
                            var u = updated; u.rect = clamped
                            objects[idx] = .badge(u)
                        default:
                            break
                        }
                        dragStartPoint = p
                    }
                }
            }
            .onEnded { value in
                let endFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let pEnd = fittedToAuthorPoint(endFit, fitted: fitted, author: author)
                let pStart = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                
                let dx = pEnd.x - pStart.x
                let dy = pEnd.y - pStart.y
                let moved = hypot(dx, dy) > 5 // threshold similar to text/pointer
                
                defer { dragStartPoint = nil; pushedDragUndo = false; activeHandle = .none }
                
                // If we interacted with an existing badge (moved/resized), do not create a new one
                if moved, selectedObjectID != nil {
                    return
                }
                
                // If we started on a badge but didn’t move enough, just select it and return
                if let sel = selectedObjectID, let idx = objects.firstIndex(where: { $0.id == sel }) {
                    if case .badge(let o) = objects[idx], o.hitTest(pStart) || o.handleHitTest(pStart) != .none {
                        return
                    }
                }
                
                // Otherwise, create a new badge at the click location
                let diameter: CGFloat = 32
                let rect = CGRect(x: max(0, pEnd.x - diameter/2),
                                  y: max(0, pEnd.y - diameter/2),
                                  width: diameter,
                                  height: diameter)
                let rectClamped = clampRect(rect, in: author)
                badgeCount &+= 1
                let newObj = BadgeObject(rect: rectClamped, number: badgeCount, fillColor: badgeColor, textColor: .white)
                pushUndoSnapshot()
                objects.append(.badge(newObj))
                if objectSpaceSize == nil { objectSpaceSize = author }
                selectedObjectID = newObj.id
            }
    }
    
    private func cropGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let currentFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                
                // Convert to fitted coordinate space for crop (not author space)
                let startFitted = startFit
                let currentFitted = currentFit
                
                // If we already have a cropRect, interpret drags as edits (handles or move)
                if let existing = cropRect {
                    if cropDragStart == nil {
                        cropDragStart = startFitted
                        cropOriginalRect = existing
                        // Decide if we're on a handle; otherwise, treat as move if inside rect
                        cropHandle = cropHandleHitTest(existing, at: startFitted)
                        if cropHandle == .none && existing.contains(startFitted) {
                            cropHandle = .none // move
                        }
                    }
                    if let originRect = cropOriginalRect, let s = cropDragStart {
                        if cropHandle == .none && originRect.contains(s) {
                            // Move
                            let dx = currentFitted.x - s.x
                            let dy = currentFitted.y - s.y
                            var moved = originRect
                            moved.origin.x += dx
                            moved.origin.y += dy
                            cropRect = clampRect(moved, in: fitted) // clamp to fitted space
                        } else {
                            // Resize using handle
                            cropRect = clampRect(resizeRect(originRect, handle: cropHandle, to: currentFitted), in: fitted)
                        }
                    }
                    return
                }
                
                // No existing cropRect – create a new draft selection in fitted space
                func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
                    let x0 = min(a.x, b.x)
                    let y0 = min(a.y, b.y)
                    let w = abs(a.x - b.x)
                    let h = abs(a.y - b.y)
                    return CGRect(x: x0, y: y0, width: w, height: h)
                }
                cropDraftRect = rectFrom(startFitted, currentFitted)
            }
            .onEnded { value in
                _ = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                
                if let _ = cropOriginalRect {
                    // Finish edit
                    cropDragStart = nil
                    cropOriginalRect = nil
                    cropHandle = .none
                    return
                }
                
                // Finish creation - store in fitted coordinate space
                if let draft = cropDraftRect {
                    let clamped = clampRect(draft, in: fitted)
                    // Derive image pixel size of this selection based on current image pixel size and the un-zoomed author space.
                    // Using `author` avoids incorporating the current zoom level (which would skew the math in Fill mode).
                    let imgSize = selectedImageSize ?? currentImage?.size ?? .zero
                    let scaleX = (imgSize.width  > 0) ? (imgSize.width  / max(1, author.width))  : 0
                    let scaleY = (imgSize.height > 0) ? (imgSize.height / max(1, author.height)) : 0
                    let pxW = clamped.width  * scaleX
                    let pxH = clamped.height * scaleY
                    // Accept if at least 1×1 px in image space, or if it’s a tiny but non-zero UI rect (>0.1pt) which cropImage will clamp to 1px
                    if (pxW >= 1 && pxH >= 1) || (clamped.width > 0.1 && clamped.height > 0.1) {
                        cropRect = clamped
                    } else {
                        cropRect = nil
                    }
                }
                cropDraftRect = nil
            }
    }

    
    
    // MARK: - Canvas Coordinate System.
    // Creates drag points for tools in the toolbar.
    private struct CoordinateTransform {
        let origin: CGPoint
        let sx: CGFloat
        let sy: CGFloat
    }
    
    private func getCoordinateTransform(for image: NSImage, in geometry: GeometryProxy) -> CoordinateTransform {
        let baseFitted = imageDisplayMode == "fit" ?
        fittedImageSize(original: image.size, in: geometry.size) :
        image.size
        
        let fitted = CGSize(width: baseFitted.width * zoomLevel, height: baseFitted.height * zoomLevel)
        
        let origin = imageDisplayMode == "fit" ?
        CGPoint(x: (geometry.size.width - fitted.width)/2, y: (geometry.size.height - fitted.height)/2) :
        CGPoint.zero
        
        let author = objectSpaceSize ?? baseFitted
        let sx = fitted.width / max(1, author.width)
        let sy = fitted.height / max(1, author.height)
        
        return CoordinateTransform(
            origin: origin,
            sx: sx,
            sy: sy
        )
    }
    
    // MARK: - Editing Tools
    
    private func selectionHandlesForLine(_ o: LineObject) -> some View {
        ZStack {
            Circle().stroke(.blue, lineWidth: 1)
                .background(Circle().fill(.white))
                .frame(width: 12, height: 12)
                .position(o.start)
            
            Circle().stroke(.blue, lineWidth: 1)
                .background(Circle().fill(.white))
                .frame(width: 12, height: 12)
                .position(o.end)
        }
    }

    private func selectionHandlesForRect(_ o: RectObject) -> some View {
        let pts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
        }
    }

    private func selectionHandlesForOval(_ o: OvalObject) -> some View {
        let pts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
        }
    }

    private func selectionHandlesForText(_ o: TextObject) -> some View {
        let pts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
            
            // TextEditor for focused text (also needs to be in scaled context)
            if focusedTextID == o.id {
                TextEditor(text: Binding(
                    get: { o.text },
                    set: { newVal in
                        if let idx = objects.firstIndex(where: { $0.id == o.id }) {
                            if case .text(var t) = objects[idx] {
                                t.text = newVal
                                objects[idx] = .text(t)
                            }
                        }
                    }
                ))
                .font(.system(size: o.fontSize))
                .foregroundStyle(Color(nsColor: o.textColor))
                .background(o.bgEnabled ? Color(nsColor: o.bgColor) : Color.clear)
                .scrollContentBackground(.hidden)
                .frame(width: o.rect.width, height: o.rect.height)
                .position(x: o.rect.midX, y: o.rect.midY)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(.blue.opacity(0.6), lineWidth: 1))
                .contentShape(Rectangle())
                .focused($isTextEditorFocused)
                .onAppear {
                    DispatchQueue.main.async {
                        isTextEditorFocused = true
                    }
                }
                .onChange(of: focusedTextID) { _,newValue in
                    isTextEditorFocused = (newValue == o.id)
                }
            }
        }
    }

    private func selectionHandlesForBadge(_ o: BadgeObject) -> some View {
        let pts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
        }
    }

    private func selectionHandlesForHighlight(_ o: HighlightObject) -> some View {
        let pts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
        }
    }

    private func selectionHandlesForImage(_ o: PastedImageObject) -> some View {
        let pts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
        }
    }
    
    // Arrow Tool
    private func arrowHeadPath(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> Path {
        var path = Path()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return path }

        // Direction unit vector from start -> end
        let ux = dx / len
        let uy = dy / len

        // Bigger head: scale with stroke width, but cap by a fraction of the line length
        let desired = max(16, lineWidth * 6.0)
        let capped  = min(len * 0.35, 280)
        let headLength = min(desired, capped)
        let headWidth  = headLength * 0.90

        let tip = end
        let baseX = tip.x - headLength * ux
        let baseY = tip.y - headLength * uy

        let px = -uy, py = ux // perpendicular
        let left  = CGPoint(x: baseX + (headWidth * 0.5) * px, y: baseY + (headWidth * 0.5) * py)
        let right = CGPoint(x: baseX - (headWidth * 0.5) * px, y: baseY - (headWidth * 0.5) * py)

        path.move(to: tip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        return path
    }
    
    
    private func flattenAndSaveInPlace() {
        guard let img = currentImage else { return }
        if objectSpaceSize == nil { objectSpaceSize = lastFittedSize ?? img.size }
        pushUndoSnapshot()
        if let flattened = rasterize(base: img, objects: objects) {
            objects.removeAll()
            if let url = selectedSnapURL {
                // Write the flattened image back to the same file
                if ImageSaver.writeImage(flattened, to: url, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                    refreshGalleryAfterSaving(to: url)
                    reloadCurrentImage()
                }
            } else {
                saveAsCurrent()
            }
        }
    }
    
    private func flattenAndSaveAs() {
        guard let img = currentImage else { return }
        if objectSpaceSize == nil { objectSpaceSize = lastFittedSize ?? img.size }
        pushUndoSnapshot()
        if let flattened = rasterize(base: img, objects: objects) {
            objects.removeAll()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [preferredSaveFormat.utType]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            if let sel = selectedSnapURL {
                panel.directoryURL = sel.deletingLastPathComponent()
                panel.nameFieldStringValue = sel.lastPathComponent
            } else if let dir = snapsDirectory() {
                panel.directoryURL = dir
                panel.nameFieldStringValue = ImageSaver.generateFilename(for: preferredSaveFormat.rawValue)
            }
            if panel.runModal() == .OK, let url = panel.url {
                if ImageSaver.writeImage(flattened, to: url, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                    selectedSnapURL = url
                    refreshGalleryAfterSaving(to: url)
                    reloadCurrentImage()
                }
            }
        }
    }
    
    private func rasterize(base: NSImage, objects: [Drawable]) -> NSImage? {
        // Keep logical canvas in points (matches editor), but render into a bitmap using the base image's backing pixels.
        let imgSize = base.size // points

        // Determine backing pixel dimensions (prefer CGImage; else largest bitmap rep; else fall back to points)
        let pixelDims: (w: Int, h: Int) = {
            if let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return (cg.width, cg.height)
            }
            if let best = base.representations
                .compactMap({ $0 as? NSBitmapImageRep })
                .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
                return (best.pixelsWide, best.pixelsHigh)
            }
            return (Int(round(imgSize.width)), Int(round(imgSize.height)))
        }()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, pixelDims.w),
            pixelsHigh: max(1, pixelDims.h),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        // Critical: set logical size (points). Drawing uses points; pixels are handled by the rep's pixel size.
        rep.size = imgSize

        let composed = NSImage(size: imgSize)
        composed.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high

            // Draw the base image to fill the logical canvas
            base.draw(in: CGRect(origin: .zero, size: imgSize))

            // Render overlay objects. These utilities assume `image` is in points, which matches `imgSize`.
            let fitted = objectSpaceSize ?? lastFittedSize ?? imgSize
            let scaleX = imgSize.width / max(1, fitted.width)
            let scaleY = imgSize.height / max(1, fitted.height)
            let scaleW = (scaleX + scaleY) / 2

            for obj in objects {
                switch obj {
                case .line(let o):
                    let s = uiToImagePoint(o.start, fitted: fitted, image: imgSize)
                    let e = uiToImagePoint(o.end,   fitted: fitted, image: imgSize)
                    let widthScaled = o.width * scaleW
                    o.color.setStroke(); o.color.setFill()
                    let path = NSBezierPath()
                    path.lineWidth = widthScaled
                    path.lineCapStyle = o.arrow ? .butt : .round
                    path.move(to: s)
                    
                    // If arrow, shorten the line so it doesn't extend under the arrow head
                    if o.arrow {
                        let dx = e.x - s.x, dy = e.y - s.y
                        let len = max(1, hypot(dx, dy))
                        let ux = dx / len, uy = dy / len
                        
                        let desired = max(16, widthScaled * 6.0)
                        let capped  = min(len * 0.35, 280)
                        let headLength = min(desired, capped)
                        
                        // Stop the line at the base of the arrow head
                        let lineEnd = CGPoint(x: e.x - ux * headLength, y: e.y - uy * headLength)
                        path.line(to: lineEnd)
                    } else {
                        path.line(to: e)
                    }
                    
                    path.stroke()
                    
                    if o.arrow {
                        let dx = e.x - s.x, dy = e.y - s.y
                        let len = max(1, hypot(dx, dy))
                        let ux = dx / len, uy = dy / len

                        let desired = max(16, widthScaled * 6.0)
                        let capped  = min(len * 0.35, 280)
                        let headLength = min(desired, capped)
                        let headWidth  = headLength * 0.90

                        // Arrow head at the exact end point
                        let bx = e.x - ux * headLength
                        let by = e.y - uy * headLength
                        let px = -uy, py = ux
                        let p1 = CGPoint(x: bx + (headWidth * 0.5) * px, y: by + (headWidth * 0.5) * py)
                        let p2 = CGPoint(x: bx - (headWidth * 0.5) * px, y: by - (headWidth * 0.5) * py)

                        let tri = NSBezierPath()
                        tri.move(to: e)  // Tip at exact end point
                        tri.line(to: p1)
                        tri.line(to: p2)
                        tri.close()
                        tri.fill()
                    }
                case .rect(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    o.color.setStroke()
                    let path = NSBezierPath(rect: r); path.lineWidth = o.width * scaleW; path.stroke()
                case .oval(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    o.color.setStroke()
                    let path = NSBezierPath(ovalIn: r)
                    path.lineWidth = o.width * scaleW
                    path.stroke()
                case .text(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    if o.bgEnabled { let bg = NSBezierPath(rect: r); o.bgColor.setFill(); bg.fill() }
                    let para = NSMutableParagraphStyle(); para.alignment = .left; para.lineBreakMode = .byWordWrapping
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: o.fontSize * scaleW),
                        .foregroundColor: o.textColor,
                        .paragraphStyle: para
                    ]
                    NSString(string: o.text).draw(in: r.insetBy(dx: 4 * scaleW, dy: 4 * scaleW), withAttributes: attrs)
                case .badge(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    let circle = NSBezierPath(ovalIn: r); o.fillColor.setFill(); circle.fill()
                    let para = NSMutableParagraphStyle(); para.alignment = .center
                    let fontSize = min(r.width, r.height) * 0.6
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                        .foregroundColor: o.textColor,
                        .paragraphStyle: para
                    ]
                    NSString(string: "\(o.number)").draw(in: r, withAttributes: attrs)
                case .highlight(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    o.color.setFill(); NSBezierPath(rect: r).fill()
                case .image(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    o.image.draw(in: r)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return composed
    }
    
    private func deleteSelectedObject() {
        // If the inline TextEditor has keyboard focus, do NOT delete the text object.
        // This lets the Delete/Backspace key edit text content instead of removing the box.
        if isTextEditorFocused {
            return
        }
        guard let sel = selectedObjectID, let idx = objects.firstIndex(where: { $0.id == sel }) else { return }
        pushUndoSnapshot()
        objects.remove(at: idx)
        selectedObjectID = nil
        activeHandle = .none
    }
    
    private func performUndo() {
        guard let prev = undoStack.popLast() else { return }
        let current = Snapshot(imageURL: selectedSnapURL, objects: objects)
        redoStack.append(current)
        selectedSnapURL = prev.imageURL  // Just change the URL
        objects = prev.objects
        
        updateMenuState()

    }
    
    private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        let current = Snapshot(imageURL: selectedSnapURL, objects: objects)
        undoStack.append(current)
        selectedSnapURL = next.imageURL  // Just change the URL
        objects = next.objects
        
        updateMenuState()

    }
    
    private func clampPoint(_ p: CGPoint, in fitted: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x), fitted.width),
                y: min(max(0, p.y), fitted.height))
    }
    private func clampRect(_ r: CGRect, in fitted: CGSize) -> CGRect {
        let x = max(0, min(r.origin.x, fitted.width))
        let y = max(0, min(r.origin.y, fitted.height))
        let w = max(0, min(r.width,  fitted.width  - x))
        let h = max(0, min(r.height, fitted.height - y))
        return CGRect(x: x, y: y, width: w, height: h)
    }
    
    private func fittedImageSize(original: CGSize, in container: CGSize) -> CGSize {
        let scale = min(container.width / max(1, original.width), container.height / max(1, original.height))
        return CGSize(width: original.width * scale, height: original.height * scale)
    }
    
    private func uiToImagePoint(_ p: CGPoint, fitted: CGSize, image: CGSize) -> CGPoint {
        let p = clampPoint(p, in: fitted)
        let scaleX = image.width / max(1, fitted.width)
        let scaleY = image.height / max(1, fitted.height)
        // UI: (0,0) top-left (Y down) -> Image: (0,0) bottom-left (Y up)
        return CGPoint(x: p.x * scaleX, y: (fitted.height - p.y) * scaleY)
    }
    
    private func uiRectToImageRect(_ r: CGRect, fitted: CGSize, image: CGSize) -> CGRect {
        let r = clampRect(r, in: fitted)
        let scaleX = image.width / max(1, fitted.width)
        let scaleY = image.height / max(1, fitted.height)
        let x = r.origin.x * scaleX
        let width = r.width * scaleX
        let height = r.height * scaleY
        // Convert Y coordinate: UI top-left origin to image bottom-left origin
        let y = (fitted.height - (r.origin.y + r.height)) * scaleY
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    // Shift snapping for straight lines at 0°/45°/90°
    private func snappedPoint(start: CGPoint, raw: CGPoint) -> CGPoint {
        let dx = raw.x - start.x
        let dy = raw.y - start.y
        let adx = abs(dx)
        let ady = abs(dy)
        if adx == 0 && ady == 0 { return raw }
        // Thresholds for 22.5° and 67.5° to decide snapping band
        let tan22: CGFloat = 0.41421356  // tan(22.5°)
        let tan67: CGFloat = 2.41421356  // tan(67.5°)
        
        if ady <= adx * tan22 { // Horizontal
            return CGPoint(x: start.x + dx, y: start.y)
        } else if ady >= adx * tan67 { // Vertical
            return CGPoint(x: start.x, y: start.y + dy)
        } else { // Diagonal 45°
            let m = max(adx, ady)
            let sx: CGFloat = dx >= 0 ? 1 : -1
            let sy: CGFloat = dy >= 0 ? 1 : -1
            return CGPoint(x: start.x + sx * m, y: start.y + sy * m)
        }
    }
    
    private func pasteFromClipboard() {
        // If a TextEditor is focused, let it handle paste itself.
        if isTextEditorFocused { return }
        
        let pb = NSPasteboard.general
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let img = imgs.first {
            // Choose author space (object coord system)
            let author = objectSpaceSize ?? lastFittedSize ?? currentImage?.size ?? CGSize(width: 1200, height: 800)
            
            let natural = img.size
            let aspect = (natural.height == 0) ? 1 : (natural.width / natural.height)
            
            // Sensible default size
            var w = min(480, author.width * 0.6)
            var h = w / aspect
            if h > author.height * 0.6 { h = author.height * 0.6; w = h * aspect }
            
            // Center in author space
            let rect = CGRect(
                x: max(0, (author.width - w)/2),
                y: max(0, (author.height - h)/2),
                width: w, height: h
            )
            
            let obj = PastedImageObject(rect: rect, image: img)
            pushUndoSnapshot()
            objects.append(.image(obj))
            if objectSpaceSize == nil { objectSpaceSize = author }
            selectedObjectID = obj.id
            activeHandle = .none
            // no focus change for text
        }
    }
    
    // MARK: - Snaps Persistence
    
    //    /// Directory where we store PNG snaps.
    //    private func snapsDirectory() -> URL? {
    //        let fm = FileManager.default
    //        if let pics = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
    //            let dir = pics.appendingPathComponent("screenshotG Snaps", isDirectory: true)
    //            if !fm.fileExists(atPath: dir.path) {
    //                do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
    //            }
    //            return dir
    //        }
    //        return nil
    //    }
    
    private func snapsDirectory() -> URL? {
        // If the user has chosen a custom destination, use it
        if !saveDirectoryPath.isEmpty {
            let custom = URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
            return custom
        }
        // Default: ~/Pictures/Screen Snap
        let fm = FileManager.default
        if let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
            let dir = pictures.appendingPathComponent("Screen Snap", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        return nil
    }
    
    
    private var currentImage: NSImage? {
        guard let url = selectedSnapURL else { return nil }
        return NSImage(contentsOf: url)  // Load on-demand
    }
    
    /// Loads existing snaps on disk (all supported formats), newest first.
    private func loadExistingSnaps() {
        guard let dir = snapsDirectory() else { return }
        let fm = FileManager.default
        do {
            let supportedExtensions = Set(["png", "jpg", "jpeg", "heic"])
            let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            let dated: [(URL, Date)] = urls.compactMap {
                let vals = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                return ($0, vals?.contentModificationDate ?? .distantPast)
            }
            let sorted = dated.sorted { $0.1 > $1.1 }.map { $0.0 }
            snapURLs = Array(sorted.prefix(10))
            
            // Clean up missing URLs from our tracking set
            missingSnapURLs = missingSnapURLs.filter { !sorted.contains($0) }
            
            // If currently selected snap no longer exists, clear selection
            if let sel = selectedSnapURL, !sorted.contains(sel) {
                selectedSnapURL = nil
            }
        } catch {
            snapURLs = []
        }
    }
    
    /// Opens the snaps directory in Finder as a simple "gallery" view.
    private func openSnapsInFinder() {
        guard let dir = snapsDirectory() else { return }
        NSWorkspace.shared.open(dir)
    }
    
    private func openSnapsInGallery() {
        guard let dir = snapsDirectory() else { return }
        let fm = FileManager.default
        var urls: [URL] = []
        do {
            let all = try fm.contentsOfDirectory(at: dir,
                                                 includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                 options: [.skipsHiddenFiles])
            // Allow common raster image types
            let allowedExts: Set<String> = ["png", "jpg", "jpeg", "heic"]
            let filtered = all.filter { allowedExts.contains($0.pathExtension.lowercased()) }
            let dated: [(URL, Date)] = filtered.compactMap {
                let vals = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                return ($0, vals?.contentModificationDate ?? .distantPast)
            }
            urls = dated.sorted { $0.1 > $1.1 }.map { $0.0 }
        } catch {
            urls = []
        }

        // Fallback: if we failed to enumerate, do nothing
        guard !urls.isEmpty else { return }

        GalleryWindow.shared.present(
            urls: urls,
            onSelect: { url in
                // Check if file exists before trying to load
                let fm = FileManager.default
                if !fm.fileExists(atPath: url.path) {
                    // File is missing - add to missing set and remove from snapURLs
                    missingSnapURLs.insert(url)
                    if let index = snapURLs.firstIndex(of: url) {
                        snapURLs.remove(at: index)
                    }
                    return
                }
                
                // File exists - load it into the editor using the same logic as the main thumbnail view
                selectedSnapURL = url
                selectedImageSize = probeImageSize(url)
                
                // Clear all editing state when switching images (same as main thumbnail logic)
                objects.removeAll()
                objectSpaceSize = nil
                selectedObjectID = nil
                activeHandle = .none
                cropRect = nil
                cropDraftRect = nil
                cropHandle = .none
                focusedTextID = nil
                
                // Clear undo/redo stacks for the new image
                undoStack.removeAll()
                redoStack.removeAll()
                
                // Reset zoom and image reload trigger
                zoomLevel = 1.0
                imageReloadTrigger = UUID()
                
                // Close the gallery window
                GalleryWindow.shared.close()
            },
            onReload: {
                let fm = FileManager.default
                guard let dir = snapsDirectory() else { return [] }
                do {
                    let all = try fm.contentsOfDirectory(at: dir,
                                                         includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                         options: [.skipsHiddenFiles])
                    let allowedExts: Set<String> = ["png", "jpg", "jpeg", "heic"]
                    let filtered = all.filter { allowedExts.contains($0.pathExtension.lowercased()) }
                    let dated: [(URL, Date)] = filtered.compactMap {
                        let vals = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                        return ($0, vals?.contentModificationDate ?? .distantPast)
                    }
                    return dated.sorted { $0.1 > $1.1 }.map { $0.0 }
                } catch {
                    return []
                }
            }
        )
    }
    
    /// Inserts a newly saved URL at the start of the list (leftmost), de-duplicating if necessary.
    private func insertSnapURL(_ url: URL) {
        if let idx = snapURLs.firstIndex(of: url) {
            snapURLs.remove(at: idx)
        }
        snapURLs.insert(url, at: 0)
    }

    /// Select a snap URL, probe its pixel size and reset view state
    private func selectSnap(_ url: URL) {
        // Reset undo/redo for a fresh image session
        undoStack.removeAll()
        redoStack.removeAll()
        // Set selection and compute size (no NSImage held in state)
        selectedSnapURL = url
        lastFittedSize = nil
        // Clear editing state
        objects.removeAll()
        objectSpaceSize = nil
        selectedObjectID = nil
        activeHandle = .none
        cropRect = nil
        cropDraftRect = nil
        cropHandle = .none
    }
    
    /// Delete a snap from disk and update gallery/selection.
    private func deleteSnap(_ url: URL) {
        let fm = FileManager.default
        // Prefer moving to Trash; fall back to remove.
        do {
            var trashedURL: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashedURL)
        } catch {
            try? fm.removeItem(at: url)
        }
        // Update gallery list
        if let idx = snapURLs.firstIndex(of: url) {
            snapURLs.remove(at: idx)
        }
        // Update current selection / preview
        if selectedSnapURL == url {
            selectedSnapURL = snapURLs.first
            if let sel = selectedSnapURL {
                selectedImageSize = probeImageSize(sel)
                lastFittedSize = nil
            } else {
                selectedImageSize = nil
                lastFittedSize = nil
            }
        }
    }
    
}




/// A full-desktop translucent overlay that lets the user click–drag to choose a rectangle.
private struct SelectionOverlay: View {
    let windowOrigin: CGPoint
    let onComplete: (CGRect) -> Void
    let onCancel: () -> Void
    
    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Create the dimmed overlay with a cut-out
                if let rect = selectionRect() {
                    // Overlay that covers everything except the selection
                    Color.black.opacity(0.3)
                        .mask(
                            Rectangle()
                                .overlay(
                                    Rectangle()
                                        .frame(width: rect.width, height: rect.height)
                                        .position(x: rect.midX, y: rect.midY)
                                        .blendMode(.destinationOut)
                                )
                        )
                    
                    // Selection border
                    Rectangle()
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)
                } else {
                    // Initial overlay before dragging starts
                    Color.black.opacity(0.1)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geo))
            .onTapGesture(count: 2) {
                // Handle double-tap cancellation
                onCancel()
            }
        }
    }
    
    private func dragGesture(in geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Keep local coordinates for correct on-screen rendering
                if startPoint == nil { startPoint = value.startLocation }
                currentPoint = value.location
            }
            .onEnded { value in
                // Convert both endpoints to global screen coords for capture math
                let gStart = globalPoint(from: value.startLocation, in: geo)
                let gEnd   = globalPoint(from: value.location, in: geo)
                let rect = buildRect(from: gStart, to: gEnd)
                startPoint = nil
                currentPoint = nil
                if let rect, rect.width > 2, rect.height > 2 {
                    onComplete(rect)
                } else {
                    onCancel()
                }
            }
    }
    
    private func globalPoint(from local: CGPoint, in geo: GeometryProxy) -> CGPoint {
        // SwiftUI local coordinates are top-left–origin with Y down.
        // Global screen coordinates are bottom-left–origin with Y up.
        return CGPoint(
            x: windowOrigin.x + local.x,
            y: windowOrigin.y + (geo.size.height - local.y)
        )
    }
    
    private func selectionRect() -> CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }
    
    private func buildRect(from start: CGPoint?, to end: CGPoint) -> CGRect? {
        guard let start else { return nil }
        return CGRect(x: min(start.x, end.x),
                      y: min(start.y, end.y),
                      width: abs(start.x - end.x),
                      height: abs(start.y - end.y))
    }
}




/// Creates a cut-out effect by punching a clear rectangle in an opaque layer.
private struct SelectionShape: Shape {
    var rect: CGRect
    func path(in bounds: CGRect) -> Path {
        var p = Path(bounds) // fill the window’s bounds
        p.addRect(rect)      // punch the selection rect out
        return p
    }
}

private struct CopiedHUD: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text("Copied to Clipboard")
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
        .shadow(radius: 6)
    }
}

// MARK: - Object Editing Models
private enum Handle: Hashable { case none, lineStart, lineEnd, rectTopLeft, rectTopRight, rectBottomLeft, rectBottomRight }

private protocol DrawableObject: Identifiable, Equatable {}

private struct LineObject: DrawableObject {
    let id: UUID
    var start: CGPoint
    var end: CGPoint
    var width: CGFloat
    var arrow: Bool
    var color: NSColor  // Add color property
    
    init(id: UUID = UUID(), start: CGPoint, end: CGPoint, width: CGFloat, arrow: Bool, color: NSColor = .black) {
        self.id = id; self.start = start; self.end = end; self.width = width; self.arrow = arrow; self.color = color
    }
    
    static func == (lhs: LineObject, rhs: LineObject) -> Bool {
        lhs.id == rhs.id && lhs.start == rhs.start && lhs.end == rhs.end && lhs.width == rhs.width && lhs.arrow == rhs.arrow && lhs.color == rhs.color
    }
    
    func drawPath(in _: CGSize) -> Path { var p = Path(); p.move(to: start); p.addLine(to: end); return p }
    
    func hitTest(_ p: CGPoint) -> Bool {
        let tol = max(6, width + 6)
        let dx = end.x - start.x, dy = end.y - start.y
        let len2 = dx*dx + dy*dy
        if len2 == 0 { return hypot(p.x-start.x, p.y-start.y) <= tol }
        let t = max(0, min(1, ((p.x-start.x)*dx + (p.y-start.y)*dy)/len2))
        let proj = CGPoint(x: start.x + t*dx, y: start.y + t*dy)
        return hypot(p.x-proj.x, p.y-proj.y) <= tol
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        if CGRect(x: start.x-r, y: start.y-r, width: 2*r, height: 2*r).contains(p) { return .lineStart }
        if CGRect(x: end.x-r,   y: end.y-r,   width: 2*r, height: 2*r).contains(p) { return .lineEnd }
        return .none
    }
    
    func moved(by d: CGSize) -> LineObject {
        var c = self
        c.start.x += d.width; c.start.y += d.height
        c.end.x   += d.width; c.end.y   += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> LineObject {
        var c = self
        switch handle { case .lineStart: c.start = p; case .lineEnd: c.end = p; default: break }
        return c
    }
}

private struct RectObject: DrawableObject {
    let id: UUID
    var rect: CGRect
    var width: CGFloat
    var color: NSColor  // Add color property
    
    init(id: UUID = UUID(), rect: CGRect, width: CGFloat, color: NSColor = .black) {
        self.id = id; self.rect = rect; self.width = width; self.color = color
    }
    
    static func == (lhs: RectObject, rhs: RectObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.width == rhs.width && lhs.color == rhs.color
    }
    
    func drawPath(in _: CGSize) -> Path { Rectangle().path(in: rect) }
    
    func hitTest(_ p: CGPoint) -> Bool {
        let inset = -max(6, width + 6)
        return rect.insetBy(dx: inset, dy: inset).contains(p) && !rect.insetBy(dx: max(6, width + 6), dy: max(6, width + 6)).contains(p)
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }
    
    func moved(by d: CGSize) -> RectObject { var c = self; c.rect.origin.x += d.width; c.rect.origin.y += d.height; return c }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> RectObject {
        var c = self
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x, y: p.y, width: rect.maxX - p.x, height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX, y: p.y, width: p.x - rect.minX, height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x, y: rect.minY, width: rect.maxX - p.x, height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX, y: rect.minY, width: p.x - rect.minX, height: p.y - rect.minY)
        default: break
        }
        return c
    }
}

private struct OvalObject: DrawableObject {
    let id: UUID
    var rect: CGRect
    var width: CGFloat
    var color: NSColor  // Add color property

    init(id: UUID = UUID(), rect: CGRect, width: CGFloat, color: NSColor = .black) {
        self.id = id
        self.rect = rect
        self.width = width
        self.color = color
    }

    static func == (lhs: OvalObject, rhs: OvalObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.width == rhs.width && lhs.color == rhs.color
    }

    func drawPath(in _: CGSize) -> Path {
        Ellipse().path(in: rect)
    }

    func hitTest(_ p: CGPoint) -> Bool {
        // Ellipse hit test: normalize point into ellipse space and check if inside
        let rx = rect.width / 2.0
        let ry = rect.height / 2.0
        guard rx > 0, ry > 0 else { return false }
        let cx = rect.midX
        let cy = rect.midY
        let nx = (p.x - cx) / rx
        let ny = (p.y - cy) / ry
        return (nx * nx + ny * ny) <= 1.0
    }

    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }

    func moved(by d: CGSize) -> OvalObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }

    func resizing(_ handle: Handle, to p: CGPoint) -> OvalObject {
        var c = self
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x,
                            y: p.y,
                            width: rect.maxX - p.x,
                            height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX,
                            y: p.y,
                            width: p.x - rect.minX,
                            height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x,
                            y: rect.minY,
                            width: rect.maxX - p.x,
                            height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX,
                            y: rect.minY,
                            width: p.x - rect.minX,
                            height: p.y - rect.minY)
        default:
            break
        }
        // Prevent negative or tiny sizes
        c.rect.size.width = max(2, c.rect.size.width)
        c.rect.size.height = max(2, c.rect.size.height)
        return c
    }
}

private struct HighlightObject: DrawableObject {
    let id: UUID
    var rect: CGRect
    var color: NSColor // include alpha for the “marker” look
    
    init(id: UUID = UUID(),
         rect: CGRect,
         color: NSColor = NSColor.systemYellow.withAlphaComponent(0.35)) {
        self.id = id; self.rect = rect; self.color = color
    }
    
    static func == (lhs: HighlightObject, rhs: HighlightObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.color == rhs.color
    }
    
    func hitTest(_ p: CGPoint) -> Bool {
        rect.insetBy(dx: -6, dy: -6).contains(p)
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }
    
    func moved(by d: CGSize) -> HighlightObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> HighlightObject {
        var c = self
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x, y: p.y, width: rect.maxX - p.x, height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX, y: p.y, width: p.x - rect.minX, height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x, y: rect.minY, width: rect.maxX - p.x, height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX, y: rect.minY, width: p.x - rect.minX, height: p.y - rect.minY)
        default: break
        }
        return c
    }
}

private struct TextObject: DrawableObject {
    let id: UUID
    var rect: CGRect
    var text: String
    var fontSize: CGFloat
    var textColor: NSColor
    var bgEnabled: Bool
    var bgColor: NSColor
    
    init(id: UUID = UUID(), rect: CGRect, text: String, fontSize: CGFloat, textColor: NSColor, bgEnabled: Bool, bgColor: NSColor) {
        self.id = id; self.rect = rect; self.text = text; self.fontSize = fontSize; self.textColor = textColor; self.bgEnabled = bgEnabled; self.bgColor = bgColor
    }
    
    static func == (lhs: TextObject, rhs: TextObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.text == rhs.text && lhs.fontSize == rhs.fontSize && lhs.textColor == rhs.textColor && lhs.bgEnabled == rhs.bgEnabled && lhs.bgColor == rhs.bgColor
    }
    
    func hitTest(_ p: CGPoint) -> Bool { rect.insetBy(dx: -6, dy: -6).contains(p) }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }
    
    func moved(by d: CGSize) -> TextObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> TextObject {
        var c = self
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x, y: p.y, width: rect.maxX - p.x, height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX, y: p.y, width: p.x - rect.minX, height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x, y: rect.minY, width: rect.maxX - p.x, height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX, y: rect.minY, width: p.x - rect.minX, height: p.y - rect.minY)
        default: break
        }
        c.rect.size.width = max(10, c.rect.size.width)
        c.rect.size.height = max(10, c.rect.size.height)
        return c
    }
}

private struct BadgeObject: DrawableObject {
    let id: UUID
    var rect: CGRect
    var number: Int
    var fillColor: NSColor
    var textColor: NSColor
    
    init(id: UUID = UUID(), rect: CGRect, number: Int, fillColor: NSColor, textColor: NSColor) {
        self.id = id; self.rect = rect; self.number = number; self.fillColor = fillColor; self.textColor = textColor
    }
    
    static func == (lhs: BadgeObject, rhs: BadgeObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.number == rhs.number && lhs.fillColor == rhs.fillColor && lhs.textColor == rhs.textColor
    }
    
    func hitTest(_ p: CGPoint) -> Bool {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = max(rect.width, rect.height) / 2 + 6
        return hypot(p.x - c.x, p.y - c.y) <= radius
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }
    
    func moved(by d: CGSize) -> BadgeObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> BadgeObject {
        var c = self
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x, y: p.y, width: rect.maxX - p.x, height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX, y: p.y, width: p.x - rect.minX, height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x, y: rect.minY, width: rect.maxX - p.x, height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX, y: rect.minY, width: p.x - rect.minX, height: p.y - rect.minY)
        default: break
        }
        let side = max(8, (c.rect.width + c.rect.height) / 2)
        c.rect.size = CGSize(width: side, height: side)
        return c
    }
}

private struct PastedImageObject: DrawableObject {
    let id: UUID
    var rect: CGRect
    var image: NSImage
    /// Natural aspect ratio (w / h) for Shift-resize.
    let aspect: CGFloat
    
    init(id: UUID = UUID(), rect: CGRect, image: NSImage) {
        self.id = id
        self.rect = rect
        self.image = image
        let s = image.size
        self.aspect = (s.height == 0) ? 1 : (s.width / s.height)
    }
    
    static func == (lhs: PastedImageObject, rhs: PastedImageObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.image == rhs.image
    }
    
    func hitTest(_ p: CGPoint) -> Bool { rect.insetBy(dx: -6, dy: -6).contains(p) }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }
    
    func moved(by d: CGSize) -> PastedImageObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> PastedImageObject {
        var c = self
        let keepAspect = NSEvent.modifierFlags.contains(.shift)
        
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x, y: p.y, width: rect.maxX - p.x, height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX, y: p.y, width: p.x - rect.minX, height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x, y: rect.minY, width: rect.maxX - p.x, height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX, y: rect.minY, width: p.x - rect.minX, height: p.y - rect.minY)
        default:
            break
        }
        
        c.rect.size.width  = max(8, c.rect.size.width)
        c.rect.size.height = max(8, c.rect.size.height)
        
        guard keepAspect else { return c }
        
        // Snap to original aspect by adjusting the dimension that needs the smallest change.
        let targetW = c.rect.height * aspect
        let targetH = c.rect.width / aspect
        if abs(targetW - c.rect.width) < abs(targetH - c.rect.height) {
            c.rect.size.width = targetW
        } else {
            c.rect.size.height = targetH
        }
        
        // Re-anchor based on which corner moved so the opposite corner stays fixed.
        switch handle {
        case .rectTopLeft:
            c.rect.origin.x = rect.maxX - c.rect.size.width
            c.rect.origin.y = rect.maxY - c.rect.size.height
        case .rectTopRight:
            c.rect.origin.y = rect.maxY - c.rect.size.height
        case .rectBottomLeft:
            c.rect.origin.x = rect.maxX - c.rect.size.width
        default:
            break
        }
        return c
    }
}

private enum Drawable: Identifiable, Equatable {
    case line(LineObject)
    case rect(RectObject)
    case text(TextObject)
    case badge(BadgeObject)
    case highlight(HighlightObject)
    case image(PastedImageObject)
    case oval(OvalObject)
    
    var id: UUID {
        switch self {
        case .line(let o): return o.id
        case .rect(let o): return o.id
        case .text(let o): return o.id
        case .badge(let o): return o.id
        case .highlight(let o): return o.id
        case .image(let o): return o.id
        case .oval(let o): return o.id
        }
    }
}

// MARK: - Inline Annotation Types
private struct Line: Identifiable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var width: CGFloat
}



final class ScreenCapturer: NSObject, SCStreamOutput {
    static let shared = ScreenCapturer()
    
    private var currentStream: SCStream?
    private var captureResult: CGImage?
    private var captureError: Error?
    private var isCapturing = false
    
    func captureImage(using filter: SCContentFilter, display: SCDisplay) async -> CGImage? {
        let result = await performCapture(filter: filter, config: createConfig(for: display))
        
        // CRITICAL: Clear all references immediately after capture
        defer {
            captureResult = nil
            captureError = nil
            currentStream = nil
        }
        
        return result
    }
    
    private func createConfig(for display: SCDisplay) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        let backingScale = getBackingScaleForDisplay(display) ?? 1.0
        cfg.width = Int(CGFloat(display.width) * backingScale)
        cfg.height = Int(CGFloat(display.height) * backingScale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        return cfg
    }
    
    private func performCapture(filter: SCContentFilter, config: SCStreamConfiguration) async -> CGImage? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        
        // Clear any previous state
        captureResult = nil
        captureError = nil
        currentStream = nil
        
        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            currentStream = stream
            
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            
            // Wait for result with timeout
            let startTime = CACurrentMediaTime()
            let timeout: TimeInterval = 4.0
            
            while captureResult == nil && captureError == nil {
                if CACurrentMediaTime() - startTime > timeout {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            
            await shutdownStream(stream)
            
            if let error = captureError {
                throw error
            }
            
            defer {
                captureResult = nil
                captureError = nil
                currentStream = nil
                // Add explicit autoreleasepool drain
                autoreleasepool {
                    // Force any retained objects to release
                }
            }
            
            return captureResult
            
        } catch {
            if let stream = currentStream {
                await shutdownStream(stream)
            }
            return nil
        }
    }
    
    private func shutdownStream(_ stream: SCStream) async {
        do {
            try stream.removeStreamOutput(self, type: .screen)
        } catch {
            // Ignore removal errors
        }
        
        do {
            try await stream.stopCapture()
        } catch let error as NSError {
            // Ignore "already stopped" errors
            if error.code != -3808 {
                print("Stream shutdown error: \(error)")
            }
        }
        
        currentStream = nil
    }
    
    private func getBackingScaleForDisplay(_ scDisplay: SCDisplay) -> CGFloat? {
        for screen in NSScreen.screens {
            if let cgIDNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let cgID = CGDirectDisplayID(truncating: cgIDNum)
                if cgID == scDisplay.displayID {
                    return screen.backingScaleFactor
                }
            }
        }
        return nil
    }
    
    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              captureResult == nil, // Only capture the first frame
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        
        if let cgImage = cgImage {
            captureResult = cgImage
        }
    }
}


final class SelectionWindowManager {
    static let shared = SelectionWindowManager()
    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    
    func present(onComplete: @escaping (CGRect) -> Void) {
        // Prevent re-entrancy
        guard panels.isEmpty else { return }
        
        for screen in NSScreen.screens {
            let frame = screen.frame
            let panel = NSPanel(contentRect: frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.ignoresMouseEvents = false
            panel.isMovable = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.hasShadow = false
            panel.isExcludedFromWindowsMenu = true
            panel.setFrame(frame, display: false) // ensure the window sits at the global screen frame
            
            let root = SelectionOverlay(
                windowOrigin: frame.origin,
                onComplete: { rect in
                    onComplete(rect)
                    self.dismiss()
                },
                onCancel: {
                    self.dismiss()
                }
            )
                .ignoresSafeArea()
            
            panel.contentView = NSHostingView(rootView: root)
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
        }
        
        // Activate the app so non-activating panels on all displays accept events
        NSApp.activate(ignoringOtherApps: true)
        
        // ESC to cancel selection (all panels)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // ESC
                self.dismiss()
                return nil // consume event
            }
            return event
        }
    }
    
    func dismiss() {
        for p in panels {
            p.orderOut(nil)
        }
        panels.removeAll()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}

// MARK: - Pen Color Menu Helper
private struct PenColorButton: View {
    @Binding var current: NSColor
    let color: NSColor
    let name: String
    var body: some View {
        Button(action: { current = color }) {
            HStack {
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 14, height: 14)
                Text(name)
                Spacer()
                if current.isEqual(color) { Image(systemName: "checkmark") }
            }
        }
    }
}



private func fittedToAuthorPoint(_ p: CGPoint, fitted: CGSize, author: CGSize) -> CGPoint {
    let sx = author.width / max(1, fitted.width)
    let sy = author.height / max(1, fitted.height)
    return CGPoint(x: p.x * sx, y: p.y * sy)
}


/// Crops an NSImage using a rect expressed in image coordinates with bottom-left origin.
private func cropImage(_ image: NSImage, toBottomLeftRect rBL: CGRect) -> NSImage? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let imgW = CGFloat(cg.width)
    let imgH = CGFloat(cg.height)
    // Convert to CoreGraphics top-left origin
    var rectTL = CGRect(x: rBL.origin.x,
                        y: imgH - (rBL.origin.y + rBL.height),
                        width: rBL.width,
                        height: rBL.height)
    // Normalize negative or tiny sizes
    if rectTL.width < 0 { rectTL.origin.x += rectTL.width; rectTL.size.width = -rectTL.width }
    if rectTL.height < 0 { rectTL.origin.y += rectTL.height; rectTL.size.height = -rectTL.height }
    // Clamp to image bounds
    rectTL.origin.x = max(0, min(rectTL.origin.x, imgW))
    rectTL.origin.y = max(0, min(rectTL.origin.y, imgH))
    rectTL.size.width  = max(1, min(rectTL.size.width,  imgW - rectTL.origin.x))
    rectTL.size.height = max(1, min(rectTL.size.height, imgH - rectTL.origin.y))
    // Integral pixel edges
    rectTL = rectTL.integral
    guard rectTL.width >= 1, rectTL.height >= 1 else { return nil }
    guard let sub = cg.cropping(to: rectTL) else { return nil }
    return NSImage(cgImage: sub, size: NSSize(width: rectTL.width, height: rectTL.height))
}



// A view-scoped scroll wheel handler that only reacts when the mouse is over THIS view.
private final class _ZoomCatcherView: NSView {
    var onZoom: ((CGFloat) -> Void)?
    private var tracking: NSTrackingArea?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only become the hit-test target when the Command key is held.
        // This lets trackpad pinch (magnify) reach the SwiftUI image beneath.
        if let ev = NSApp.currentEvent, ev.modifierFlags.contains(.command) {
            return self
        }
        return nil
    }
    
    override func magnify(with event: NSEvent) {
        // Do not consume pinch-to-zoom; forward it so SwiftUI's MagnificationGesture works.
        nextResponder?.magnify(with: event)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureTrackingArea()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        ensureTrackingArea()
    }
    
    private func ensureTrackingArea() {
        if let tracking { removeTrackingArea(tracking) }
        let opts: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        window?.makeFirstResponder(self)
    }
    
    override func mouseDown(with event: NSEvent) {
        // Also claim first responder on click
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    
    override func scrollWheel(with event: NSEvent) {
        // Only handle when Command is held; otherwise pass through
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        
        let deltaY: CGFloat
        if event.hasPreciseScrollingDeltas {
            deltaY = event.scrollingDeltaY
        } else {
            // Non-precise mouse: scale a bit per line step
            deltaY = event.deltaY * 10.0
        }
        
        // Convert delta into a multiplicative zoom factor
        // Small base so both trackpads and wheels feel reasonable
        let factor = pow(1.0018, deltaY)
        onZoom?(factor)
    }
}

private struct LocalScrollWheelZoomView: NSViewRepresentable {
    @Binding var zoomLevel: Double
    var minZoom: Double = 0.1
    var maxZoom: Double = 3.0
    
    func makeNSView(context: Context) -> _ZoomCatcherView {
        let v = _ZoomCatcherView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        v.onZoom = { factor in
            let newZoom = min(max(zoomLevel * Double(factor), minZoom), maxZoom)
            zoomLevel = newZoom
        }
        return v
    }
    
    func updateNSView(_ nsView: _ZoomCatcherView, context: Context) {
        // Update the zoom handler with current zoom level
        nsView.onZoom = { factor in
            let newZoom = min(max(zoomLevel * Double(factor), minZoom), maxZoom)
            zoomLevel = newZoom
        }
    }
}


// Helper so that we can save tool colors as AppStorage.
extension NSColor {
    func toData() -> Data {
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: false)
        } catch {
            // Fallback to black if archiving fails
            return try! NSKeyedArchiver.archivedData(withRootObject: NSColor.black, requiringSecureCoding: false)
        }
    }
    
    static func fromData(_ data: Data) -> NSColor? {
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        } catch {
            return nil
        }
    }
}
