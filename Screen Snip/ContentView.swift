


import SwiftUI
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import UniformTypeIdentifiers
import ImageIO
import Combine
import ServiceManagement

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


enum Tool { case pointer, line, rect, oval, text, crop, badge, highlighter }

enum SaveFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic
    var id: String { rawValue }
    var utType: UTType {
        switch self {
        case .png:  return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

}

enum CaptureMode: String, CaseIterable {
    case captureWithWindows = "captureWithWindows"
    case captureWithoutWindows = "captureWithoutWindows"
}

struct ContentView: View {
    
    @ObservedObject private var appDelegate = AppDelegate.shared
    
    @FocusState private var thumbnailsFocused: Bool

    // Zoom
    
    private let ZOOM_MIN: Double = 0.5
    private let ZOOM_MAX: Double = 3.0
    
    
    
    
    private var hasPermissionIssues: Bool {
        appDelegate.needsAccessibilityPermission || appDelegate.needsScreenRecordingPermission
    }
    
    
    // MARK: - Launch On Logon
    private static let loginHelperIdentifier = "com.georgebabichev.Screen-Snip-Helper"
    @State private var logonChecked: Bool = {
        let loginService = SMAppService.loginItem(identifier: loginHelperIdentifier)
        return loginService.status == .enabled   // True if login item is currently enabled
    }()
    
    // MARK: - Vars
    @Environment(\.openWindow) private var openWindow  // Add this line
    @State private var showingFileExporter = false
    @State private var exportImage: NSImage? = nil
    
    @AppStorage("captureMode") private var captureModeRaw: String = CaptureMode.captureWithWindows.rawValue

    
    @State private var currentGeometrySize: CGSize = CGSize(width: 800, height: 600)
    
    
    @State private var thumbnailRefreshTrigger = UUID()
    
    @State private var selectedImageSize: CGSize? = nil
    @State private var imageReloadTrigger = UUID()
    @State private var missingSnipURLs: Set<URL> = []
    @State private var zoomLevel: Double = 1.0
    @State private var pinchBaseZoom: Double? = nil
    
    @State private var showSettingsPopover = false
    @AppStorage("preferredSaveFormat") private var preferredSaveFormatRaw: String = SaveFormat.png.rawValue
    private var preferredSaveFormat: SaveFormat {
        get { SaveFormat(rawValue: preferredSaveFormatRaw) ?? .png }
        set { preferredSaveFormatRaw = newValue.rawValue }
    }
    
    @AppStorage("hideDockIcon") private var hideDockIcon: Bool = false
    @AppStorage("saveQuality") private var saveQuality: Double = 0.9
    @AppStorage("saveDirectoryPath") private var saveDirectoryPath: String = ""
    @AppStorage("downsampleToNonRetinaClipboard") private var downsampleToNonRetinaClipboard: Bool = true
    @AppStorage("downsampleToNonRetinaForSave") private var downsampleToNonRetinaForSave: Bool = false
    @AppStorage("imageDisplayMode") private var imageDisplayMode: String = "fit" // "actual" or "fit"
    @AppStorage("saveOnCopy") private var saveOnCopy: Bool = false
    
    
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
    @AppStorage("strokeWidth") private var strokeWidth: Double = 3
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
    // Snips persisted on disk (newest first). Each element is a file URL to a PNG.
    @State private var SnipURLs: [URL] = []
    @State private var selectedSnipURL: URL? = nil
    @State private var objects: [Drawable] = []
    @State private var selectedObjectID: UUID? = nil
    @State private var activeHandle: Handle = .none
    @State private var dragStartPoint: CGPoint? = nil
    
    // Undo/Redo stacks of full images and overlays (save-in-place, memory-bounded by user behavior)
    private struct Snipshot {
        let imageURL: URL?
        let objects: [Drawable]
    }
    
    @State private var undoStack: [Snipshot] = []
    @State private var redoStack: [Snipshot] = []
    @State private var pushedDragUndo = false
    @State private var keyMonitor: Any? = nil
    
    @AppStorage("textFontSize") private var textFontSize: Double = 18
    
    @AppStorage("textColor") private var textColorRaw: String = "#000000FF"
    private var textColor: NSColor {
        get { NSColor(hexRGBA: textColorRaw) ?? .black }
        set { textColorRaw = newValue.toHexRGBA() }
    }
    private var textColorBinding: Binding<NSColor> {
        Binding(get: { textColor }, set: { textColorRaw = $0.toHexRGBA() })
    }
    
    @AppStorage("textBGEnabled") private var textBGEnabled: Bool = false

    
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
    
    @AppStorage("highlighterColor") private var highlighterColorRaw: String = NSColor.systemYellow.withAlphaComponent(0.35).toHexRGBA()
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
    
    @State private var lastTextEditDoubleClickAt: CFTimeInterval = 0
    
    // Throttle rapid draft updates to ~90 Hz (for drag gestures)
    private func allowDraftTick(interval: Double = 1.0/90.0) -> Bool {
        let now = CACurrentMediaTime()
        if now - lastDraftTick < interval { return false }
        lastDraftTick = now
        return true
    }
    
    private func getActualDisplaySize(_ pixelSize: CGSize) -> CGSize {
        guard let url = selectedSnipURL else { return pixelSize }
        
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
                    if let url = selectedSnipURL, let imgSize = selectedImageSize {
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
                                    .onAppear { currentGeometrySize = geo.size }
                                    .onChange(of: geo.size) { _, newSize in currentGeometrySize = newSize }
                                    
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
                                                        .rotationEffect(Angle(radians: o.rotation))
                                                        .position(x: o.rect.midX, y: o.rect.midY)
                                                        .onTapGesture(count: 2) {
                                                            focusedTextID = o.id
                                                            isTextEditorFocused = true
                                                            lastTextEditDoubleClickAt = CACurrentMediaTime()
                                                        }
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
                                                    .rotationEffect(Angle(radians: o.rotation))
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
                                                Ellipse().path(in: r)
                                                    .stroke(Color(nsColor: ovalColor).opacity(0.8),
                                                            style: StrokeStyle(lineWidth: strokeWidth, dash: [6,4]))
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
                                    // Avoid rasterizing (compositingGroup/drawingGroup) here: it breaks NSViewRepresentable (AppKitTextEditorAdaptor) during inline editing and triggers "Unable to render flattened version..."
                                    .contentShape(Rectangle())
                                    .allowsHitTesting(true)
                                    .onTapGesture(count: 2) {
                                        // Only allow double-tap zoom when using the pointer tool and not in fit mode
                                        let now = CACurrentMediaTime()
                                        if now - lastTextEditDoubleClickAt < 0.30 { return }
                                        guard selectedTool == .pointer && imageDisplayMode != "fit" else {
                                            return
                                        }
                                        
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
                                LocalScrollWheelZoomView(zoomLevel: $zoomLevel, minZoom: ZOOM_MIN, maxZoom: ZOOM_MAX)
                                    .allowsHitTesting(true)
                            )
                            .gesture(
                                MagnificationGesture(minimumScaleDelta: 0.01)
                                    .onChanged { scale in
                                        if pinchBaseZoom == nil { pinchBaseZoom = zoomLevel }
                                        let proposed = (pinchBaseZoom ?? zoomLevel) * Double(scale)
                                        zoomLevel = min(max(proposed, ZOOM_MIN), ZOOM_MAX)
                                    }
                                    .onEnded { _ in pinchBaseZoom = nil }
                            )
                        }
                    } else {
                        // your empty/missing states unchanged
                        VStack(spacing: 12) {
                            if !missingSnipURLs.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle").imageScale(.large).foregroundStyle(.orange)
                                    Text("Some images were deleted from disk").fontWeight(.medium)
                                    Text("Press ⇧⌘2 to capture a new screenshot").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if !SnipURLs.isEmpty {
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
        //.frame(minWidth: 1200, minHeight: 400)
        .safeAreaInset(edge: .bottom) {
            if !SnipURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    
                    HStack(spacing: 6) {
                        Text("Snips")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Button(action: {
                            loadExistingSnips()
                            thumbnailRefreshTrigger = UUID()
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh Snips")
                        
                        Button(action: {
                            openSnipsInFinder()
                        }) {
                            Image(systemName: "folder")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Open Snips in Finder")
                        
                        Button(action: {
                            openSnipsInGallery()
                        }) {
                            Image(systemName: "square.grid.2x2")
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Open Snips Gallery")
                        
                        
                    }
                    .padding(.leading, 8)
                    


                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 8) {
                            ForEach(SnipURLs, id: \.self) { url in
                                VStack(spacing: 4) {
                                    ThumbnailView(
                                        url: url,
                                        selected: selectedSnipURL == url,
                                        onDelete: { deleteSnip(url) },
                                        width: 140,
                                        height: 90,
                                        refreshTrigger: thumbnailRefreshTrigger
                                    )
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // Set focus when clicking on thumbnails
                                    thumbnailsFocused = true
                                    
                                    // Check if file exists before trying to load
                                    let fm = FileManager.default
                                    if !fm.fileExists(atPath: url.path) {
                                        // File is missing - add to missing set and remove from SnipURLs
                                        missingSnipURLs.insert(url)
                                        if let index = SnipURLs.firstIndex(of: url) {
                                            SnipURLs.remove(at: index)
                                        }
                                        // If this was the selected Snip, clear selection and show error
                                        if selectedSnipURL == url {
                                            selectedSnipURL = nil
                                        }
                                        return
                                    }
                                    
                                    // File exists - load it into the editor
                                    selectedSnipURL = url
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
                    .focusable()  // Make the ScrollView focusable
                    .focused($thumbnailsFocused)  // Bind to focus state
                    .focusEffectDisabled()
                    .background(
                        // Invisible background that extends beyond thumbnails to maintain focus
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                thumbnailsFocused = true
                            }
                    )
                    .onKeyPress(keys: [.leftArrow, .rightArrow]) { keyPress in
                        // Only handle navigation if thumbnails are focused and we have thumbnails
                        guard thumbnailsFocused && !SnipURLs.isEmpty else { return .ignored }
                        
                        if keyPress.key == .leftArrow {
                            // Defer state changes to avoid "Publishing changes from within view updates" error
                            DispatchQueue.main.async {
                                navigateToAdjacentThumbnail(direction: .previous)
                            }
                            return .handled
                        } else if keyPress.key == .rightArrow {
                            DispatchQueue.main.async {
                                navigateToAdjacentThumbnail(direction: .next)
                            }
                            return .handled
                        }
                        
                        return .ignored
                    }
                    
                    
                    
                    
                    
                    
                }
                .padding(.top, 4)
                .background(.thinMaterial) // keep it distinct and readable
            }
        }
        .onAppear {
            loadExistingSnips()
            updateMenuState()
            // Listen for Cmd+Z / Shift+Cmd+Z globally while this view is active, and Delete for selected objects
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                
                if event.type == .keyDown {
                    // Auto-focus thumbnails when arrow keys are pressed and nothing specific is focused
                    if !thumbnailsFocused && !isTextEditorFocused && (event.keyCode == 123 || event.keyCode == 124) { // left/right arrows
                        DispatchQueue.main.async {
                            thumbnailsFocused = true
                        }
                        // Don't return nil here - let the event continue to be processed by the new onKeyPress handler
                    }
                }
                
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
                    if chars == "t" {
                        DispatchQueue.main.async {
                            thumbnailsFocused = true
                        }
                        return nil // consume
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
                        if let url = selectedSnipURL {
                            pushUndoSnipshot()
                            if let base = NSImage(contentsOf: url) {
                                let flattened = rasterize(base: base, objects: objects) ?? base
                                
                                // Use the SAME coordinate space calculations as the main view
                                let actualDisplaySize = getActualDisplaySize(selectedImageSize ?? CGSize(width: flattened.size.width, height: flattened.size.height))
                                
                                let fittedForUI: CGSize
                                if imageDisplayMode == "fit" {
                                    fittedForUI = fittedImageSize(original: actualDisplaySize, in: currentGeometrySize)
                                } else {
                                    fittedForUI = actualDisplaySize
                                }
                                
                                // The crop rect is in author space - convert to fitted space first
                                let authorSpace = objectSpaceSize ?? fittedForUI
                                
                                let rectInFittedSpace: CGRect
                                if authorSpace == fittedForUI {
                                    // No conversion needed - already in fitted space
                                    rectInFittedSpace = rect
                                } else {
                                    // Convert from author space to fitted space
                                    rectInFittedSpace = CGRect(
                                        x: rect.origin.x * (fittedForUI.width / authorSpace.width),
                                        y: rect.origin.y * (fittedForUI.height / authorSpace.height),
                                        width: rect.width * (fittedForUI.width / authorSpace.width),
                                        height: rect.height * (fittedForUI.height / authorSpace.height)
                                    )
                                }
                                
                                // Get pixel dimensions
                                let imagePxSize = pixelSize(of: flattened)
                                
                                // Convert from fitted space to pixel space (bottom-left origin)
                                let imgRectBL = fittedRectToImageBottomLeftRect(
                                    crpRect: rectInFittedSpace,
                                    fitted: fittedForUI,
                                    imagePx: imagePxSize
                                )
                                
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
                                        selectedImageSize = probeImageSize(url)
                                        lastFittedSize = nil
                                        imageReloadTrigger = UUID()
                                        zoomLevel = 1.0
                                    }
                                }
                            }
                        }
                        return nil
                    }
                }
                
                
                
                
                return event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNewWindow)) { _ in
            openWindow(id: "main")
        }
        .onReceive(notificationStream) { note in
            handleAppNotification(note)
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
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Save destination").bold()
                            HStack(spacing: 8) {
                                let pathText = saveDirectoryPath.isEmpty ? "Default (Pictures/Screen Snip)" : saveDirectoryPath
                                Image(systemName: "folder")
                                Text(pathText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Change...") { activeImporter = .folder }
                                if !saveDirectoryPath.isEmpty {
                                    Button {
                                        resetSaveDirectoryToDefault()
                                    } label: {
                                        Image(systemName: "arrow.counterclockwise")
                                    }
                                }
                            }
                        }
                        
                        Text("Save Format").bold()
                        Picker(selection: $preferredSaveFormatRaw, label: Image(systemName: "photo")) {
                            Text("PNG").tag(SaveFormat.png.rawValue)
                            Text("JPG").tag(SaveFormat.jpeg.rawValue)
                            Text("HEIC").tag(SaveFormat.heic.rawValue)
                        }
                        .pickerStyle(.segmented)
                        
                        if preferredSaveFormat == .jpeg || preferredSaveFormat == .heic {
                            Text("Quality").bold()
                            HStack {
                                Slider(value: $saveQuality, in: 0.4...1.0)
                                Text(String(format: "%.0f%%", saveQuality * 100))
                                .frame(width: 44, alignment: .trailing)
                            }

                        
                        }
                             
                        Divider()
                        
                        SettingsRow("Downsample Retina Screenshots", subtitle: "High DPI (4k,5k) Snips will be saved as 1x.") {
                            Toggle("", isOn: $downsampleToNonRetinaForSave)
                                .toggleStyle(.switch)
                        }
                        SettingsRow("Automatically Save on Copy", subtitle: "Edits will be immediately saved to disk when copied.") {
                            Toggle("", isOn: $saveOnCopy)
                                .toggleStyle(.switch)
                        }
                        SettingsRow("Downsample Retina Screenshots for Copy", subtitle: "High DPI images will be copied to clipboard as 1x.") {
                            Toggle("", isOn: $downsampleToNonRetinaClipboard)
                                .toggleStyle(.switch)
                                .disabled(downsampleToNonRetinaForSave && saveOnCopy)
                        }
                        
                        SettingsRow("Capture clean desktop", subtitle: "Hides app windows first, then captures a clean desktop view.\nDisabled: Captures exactly what you see on screen.") {
                            Toggle("", isOn: Binding(
                                get: { captureModeRaw == CaptureMode.captureWithoutWindows.rawValue },
                                set: { captureModeRaw = $0 ? CaptureMode.captureWithoutWindows.rawValue : CaptureMode.captureWithWindows.rawValue }
                            ))
                            .toggleStyle(.switch)
                        }
                        
                        SettingsRow("Fit image to window", subtitle: "Enabled : Fill Full Window.\nDisabled: Show True Size.") {
                            Toggle("", isOn: Binding(
                                get: { imageDisplayMode == "fit" },
                                set: { imageDisplayMode = $0 ? "fit" : "actual" }
                            ))
                            .toggleStyle(.switch)
                        }
                        
                        Divider()
                        
                        SettingsRow("Hide Dock Icon", subtitle: "App will continue to run in background.") {
                            Toggle("", isOn: $hideDockIcon)
                                .toggleStyle(.switch)
                        }

                        SettingsRow("Launch at Login", subtitle: "App will open when you logon.") {
                            Toggle("", isOn: $logonChecked)
                                .toggleStyle(.switch)
                                .onChange(of: logonChecked) {
                                    toggleLaunchAtLogin(logonChecked)
                                }
                        }
                        
                    }
                    .padding(16)
                    .frame(minWidth: 420)
                }
                
            }
            
            // Items visible only when we have a capture
            if selectedSnipURL != nil {
                
                if imageDisplayMode != "fit"{
                    ToolbarItemGroup(placement: .navigation){
                        HStack {
                            
                            Slider(value: $zoomLevel, in: ZOOM_MIN...ZOOM_MAX) {
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
                        .disabled(undoStack.isEmpty || selectedSnipURL == nil)
                        
                        // Redo
                        Button(action: performRedo) {
                            Label("Redo", systemImage: "arrow.uturn.forward")
                        }
                        .disabled(redoStack.isEmpty || selectedSnipURL == nil)
                        
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
                            highlightColorButtons(current: highlighterColorBinding)
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
                    .id("\(selectedTool)-\(lineHasArrow)-\(lineColor)-\(highlighterColor)")
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
                            highlightColorButtons(current: textBGColorBinding)
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
                    .id("\(textColor)-\(textBGEnabled)-\(textBGColor)-\(textFontSize)-\(textBGColor)")
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
            
            if hasPermissionIssues {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appDelegate.showPermissionsView = true
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .help("Missing permissions required for Screen Snip")
                    }
                }
                
                
                

            }

            
            // Capture Region button (always available)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    GlobalHotKeyManager.shared.triggerCapture()
                } label: {
                    Label("Capture Region", systemImage: "camera.viewfinder")
                }
            }
        }
        .sheet(isPresented: $appDelegate.showPermissionsView) {
            PermissionsView(
                needsAccessibility: appDelegate.needsAccessibilityPermission,
                needsScreenRecording: appDelegate.needsScreenRecordingPermission,
                onContinue: {
                    appDelegate.showPermissionsView = false
                }
            )
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
                    // ——— Directory chosen: start scope and persist bookmark for the folder ———
                    guard url.startAccessingSecurityScopedResource() else {
                        print("[Sandbox] Failed to start scope for folder: \(url.path)")
                        return
                    }
                    do {
                        let bookmarkData = try url.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                        UserDefaults.standard.set(bookmarkData, forKey: "saveDirectoryBookmark")
                        saveDirectoryPath = url.path
                    } catch {
                        print("[Sandbox] Failed to create folder bookmark: \(error)")
                        url.stopAccessingSecurityScopedResource()
                        return
                    }
                    DispatchQueue.main.async {
                        loadExistingSnips()
                    }
                } else {
                    // ——— Image file chosen: start scope and (optionally) persist bookmark for reopen ———
                    let gotScope = url.startAccessingSecurityScopedResource()
                    if !gotScope {
                        print("[Sandbox] Failed to start scope for file: \(url.path)")
                    }

                    // Persist a bookmark so future reopen flows can resolve with scope if needed
                    if let data = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil,
                                                        relativeTo: nil) {
                        UserDefaults.standard.set(data, forKey: "lastOpenedImageBookmark")
                    }

                    DispatchQueue.main.async {
                        // Clear editing state and load the picked image
                        undoStack.removeAll()
                        redoStack.removeAll()
                        selectedSnipURL = url
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
                        if let dir = SnipsDirectory(), url.path.hasPrefix(dir.path) {
                            insertSnipURL(url)
                        }
                    }
                }

            case .failure(let error):
                print("Selection canceled/failed: \(error)")
            }
        }
        .fileExporter(
            isPresented: $showingFileExporter,
            document: exportImage.map { ImageDocument(image: $0) },
            contentType: preferredSaveFormat.utType,
            defaultFilename: {
                if let sel = selectedSnipURL {
                    return sel.lastPathComponent
                } else {
                    return ImageSaver.generateFilename(for: preferredSaveFormat.rawValue)
                }
            }(),
            onCompletion: { result in
                switch result {
                case .success(let url):
                    selectedSnipURL = url
                    refreshGalleryAfterSaving(to: url)
                    reloadCurrentImage()
                case .failure(let error):
                    print("Export failed: \(error)")
                }
                exportImage = nil
            }
        )
    }
    

    private enum NavigationDirection {
        case previous, next
    }

    private func navigateToAdjacentThumbnail(direction: NavigationDirection) {
        guard !SnipURLs.isEmpty else { return }
        
        let currentIndex: Int
        if let selectedURL = selectedSnipURL,
           let index = SnipURLs.firstIndex(of: selectedURL) {
            currentIndex = index
        } else {
            // No selection, start from first
            currentIndex = direction == .next ? -1 : 0
        }
        
        let nextIndex: Int
        switch direction {
        case .next:
            nextIndex = currentIndex + 1 < SnipURLs.count ? currentIndex + 1 : 0
        case .previous:
            nextIndex = currentIndex > 0 ? currentIndex - 1 : SnipURLs.count - 1
        }
        
        let targetURL = SnipURLs[nextIndex]
        
        // Use the same loading logic as the tap gesture
        let fm = FileManager.default
        if !fm.fileExists(atPath: targetURL.path) {
            // File is missing - add to missing set and remove from SnipURLs
            missingSnipURLs.insert(targetURL)
            SnipURLs.remove(at: nextIndex)
            // Try again with updated array if we still have thumbnails
            if !SnipURLs.isEmpty {
                navigateToAdjacentThumbnail(direction: direction)
            }
            return
        }
        
        // File exists - load it into the editor
        selectedSnipURL = targetURL
        selectedImageSize = probeImageSize(targetURL)
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

    // MARK: - Launch On Logon Helpers
    // Handles enabling or disabling the login helper at login
    private func toggleLaunchAtLogin(_ enabled: Bool) {
        // Create a reference to the login item service using the static identifier
        let loginService = SMAppService.loginItem(identifier: Self.loginHelperIdentifier)
        do {
            if enabled {
                // If enabled, try to register the login helper so it launches at login
                try loginService.register()
            } else {
                // If disabled, try to unregister it
                try loginService.unregister()
            }
        } catch {
            // If anything fails, show a user-facing alert dialog with error info
            showErrorAlert(message: "Failed to update Login Item.", info: error.localizedDescription)
        }
    }

    // Utility to show an error alert dialog to the user
    private func showErrorAlert(message: String, info: String? = nil) {
        let alert = NSAlert()                  // Create a new alert
        alert.messageText = message            // Set the main alert message
        if let info = info {                   // Optionally set additional error details
            alert.informativeText = info
        }
        alert.alertStyle = .warning            // Set alert style (yellow exclamation)
        alert.runModal()                       // Display the alert as a modal dialog
    }
    
    
    
    // MARK: - Notification Handlers
    
    // Merge all notifications into a single stream the view can subscribe to.
    private var notificationStream: AnyPublisher<Notification, Never> {
        let nc = NotificationCenter.default
        return Publishers.MergeMany([
            nc.publisher(for: Notification.Name("com.georgebabichev.screenSnip.beginSnipFromIntent")),
            nc.publisher(for: .selectTool),
            nc.publisher(for: .openImageFile),
            nc.publisher(for: .copyToClipboard),
            nc.publisher(for: .performUndo),
            nc.publisher(for: .performRedo),
            nc.publisher(for: .saveImage),
            nc.publisher(for: .saveAsImage),
            nc.publisher(for: .zoomIn),
            nc.publisher(for: .zoomOut),
            nc.publisher(for: .resetZoom),
        ])
        .eraseToAnyPublisher()
    }
    
    // Central handler so the `.onReceive` body stays tiny.
    private func handleAppNotification(_ note: Notification) {
        switch note.name {
        case Notification.Name("com.georgebabichev.screenSnip.beginSnipFromIntent"):
            onBeginSnipFromIntent(note)
            
        case Notification.Name("showPermissionsView"): // Add this case
            appDelegate.showPermissionsView = false
            
        case .selectTool:
            onSelectToolNotification(note)
            
        case .openImageFile:
            onOpenImageFile()
            
        case .copyToClipboard:
            onCopyToClipboard()
            
        case .performUndo:
            onPerformUndo()
            
        case .performRedo:
            onPerformRedo()
            
        case .saveImage:
            onSaveImage()
            
        case .saveAsImage:
            onSaveAsImage()
            
        case .zoomIn, .zoomOut, .resetZoom:
            onZoomNotification(note)
            
        default:
            break
        }
    }
    
    
    private func onBeginSnipFromIntent(_ note: Notification) {
        print("🔥 [DEBUG] ContentView received beginSnipFromIntent notification")
        
        // Extract URL and activation flag from userInfo
        guard let userInfo = note.userInfo,
              let url = userInfo["url"] as? URL else {
            print("🔥 [DEBUG] ERROR: beginSnipFromIntent notification has no URL")
            return
        }
        
        //let shouldActivate = userInfo["shouldActivate"] as? Bool ?? true
        
        
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
        
        // CRITICAL: Clear any missing Snip tracking
        missingSnipURLs.removeAll()
        
        // Refresh the gallery to ensure the new Snip is in our list
        loadExistingSnips()
        
        // Set the selected Snip (this should now work since we refreshed)
        selectedSnipURL = url
        selectedImageSize = probeImageSize(url)
        updateMenuState()
    }
    private func onSelectToolNotification(_ note: Notification) {
        guard let raw = note.userInfo?["tool"] as? String else { return }
        print(raw)
        handleSelectTool(raw)
    }
    private func onOpenImageFile() { activeImporter = .image}
    private func onCopyToClipboard() {
        guard selectedSnipURL != nil else { return }
        flattenRefreshAndCopy()
        selectedTool = .pointer
        selectedObjectID = nil
        activeHandle = .none
        cropDraftRect = nil
        cropRect = nil
        cropHandle = .none
        focusedTextID = nil
    }
    private func onPerformUndo() { performUndo() }
    private func onPerformRedo() { performRedo() }
    private func onSaveImage() {
        guard selectedSnipURL != nil else { return }
        flattenAndSaveInPlace()
    }
    private func onSaveAsImage() {
        guard selectedSnipURL != nil else { return }
        flattenAndSaveAs()
    }
    private func onZoomNotification(_ notification: Notification) {
        switch notification.name {
        case .zoomIn:    zoomLevel = min(zoomLevel * 1.25, 3.0)
        case .zoomOut:   zoomLevel = max(zoomLevel / 1.25, 1.0)
        case .resetZoom: zoomLevel = 1.0
        default: break
        }
    }
    
    
    private func updateMenuState() {
        MenuState.shared.canUndo = !undoStack.isEmpty
        MenuState.shared.canRedo = !redoStack.isEmpty
        MenuState.shared.hasSelectedImage = selectedSnipURL != nil
    }
    
    private func reloadCurrentImage() {
        guard let url = selectedSnipURL else { return }
        
        // Force AsyncImage to reload by changing the trigger
        imageReloadTrigger = UUID()
        
        // Update the image size in case it changed during flattening
        selectedImageSize = probeImageSize(url)
        
        // Reset fitted size so it recalculates
        lastFittedSize = nil
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
    
    func highlightColorButton(current: Binding<NSColor>, name: String, color: NSColor) -> some View {

        let isSelected = colorsEqual(current.wrappedValue, color)
        return Button { current.wrappedValue = color } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark" : "circle.fill")
                    .foregroundStyle(Color(nsColor: color), .primary, .secondary)
                Text(name.capitalized)
            }
        }
    }

    func highlightColorButtons(current: Binding<NSColor>) -> some View {
        let options: [(name: String, color: NSColor)] = [
            ("Yellow", NSColor.systemYellow.withAlphaComponent(0.35)),
            ("Green",  NSColor.systemGreen.withAlphaComponent(0.35)),
            ("Blue",   NSColor.systemBlue.withAlphaComponent(0.35)),
            ("Pink",   NSColor.systemPink.withAlphaComponent(0.35))
        ]

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.name) { opt in
                highlightColorButton(current: current, name: opt.name, color: opt.color)
            }
        }
    }
    
    
    func colorButton(current: Binding<NSColor>, name: String, color: NSColor) -> some View {
        let isSelected = colorsEqual(current.wrappedValue, color)
        return Button { current.wrappedValue = color } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark" : "circle.fill")
                    .foregroundStyle(Color(nsColor: color), .primary, .secondary)
                Text(name.capitalized)
            }
        }
    }

    func colorButtons(current: Binding<NSColor>) -> some View {
        let colors: [(String, NSColor)] = [
            ("red", .systemRed),
            ("blue", .systemBlue),
            ("green", .systemGreen),
            ("yellow", .systemYellow),
            ("black", .black),
            ("white", .white),
            ("orange", .systemOrange),
            ("purple", .systemPurple),
            ("pink", .systemPink),
            ("gray", .systemGray)   // covers both "gray"/"grey" input
        ]

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(colors, id: \.0) { (name, color) in
                colorButton(current: current, name: name, color: color)
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
            if let url = selectedSnipURL {
                if ImageSaver.writeImage(source, to: url, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                    
                    // NEW: Clear all drawn objects after successful save
                    objects.removeAll()
                    selectedObjectID = nil
                    activeHandle = .none
                    focusedTextID = nil
                    cropRect = nil
                    cropDraftRect = nil
                    cropHandle = .none
                    
                    refreshGalleryAfterSaving(to: url)
                    reloadCurrentImage()
                    
                    
                    
                }
            } else if let dir = SnipsDirectory() {
                let newName = ImageSaver.generateFilename(for: preferredSaveFormat.rawValue)
                let dest = dir.appendingPathComponent(newName)
                if ImageSaver.writeImage(source, to: dest, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                    
                    // NEW: Clear all drawn objects after successful save
                    objects.removeAll()
                    selectedObjectID = nil
                    activeHandle = .none
                    focusedTextID = nil
                    cropRect = nil
                    cropDraftRect = nil
                    cropHandle = .none
                    
                    selectedSnipURL = dest
                    refreshGalleryAfterSaving(to: dest)
                    reloadCurrentImage()
                    
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
    
    private func pushUndoSnipshot() {
        undoStack.append(Snipshot(imageURL: selectedSnipURL, objects: objects))
        // Limit for 24/7 operation
        while undoStack.count > 3 { undoStack.removeFirst() }
        redoStack.removeAll()
        
        updateMenuState()
        
    }
    
    // MARK: - Save / Save As
    
    // Reset the custom save folder back to the default Pictures/Screen Snip directory.
    private func resetSaveDirectoryToDefault() {
        // Remove any previously stored security-scoped bookmark + path
        UserDefaults.standard.removeObject(forKey: "saveDirectoryBookmark")
        saveDirectoryPath = ""
        // Ensure the default exists and refresh the visible list
        _ = defaultSnipsDirectory()
        loadExistingSnips()
    }
    
    /// Save As… — prompts for a destination, updates gallery if under Snips folder.
    private func saveAsCurrent() {
        guard let img = currentImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [preferredSaveFormat.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if !saveDirectoryPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        }
        if let sel = selectedSnipURL {
            panel.directoryURL = sel.deletingLastPathComponent()
            panel.nameFieldStringValue = sel.lastPathComponent
        } else if let dir = SnipsDirectory() {
            panel.directoryURL = dir
            panel.nameFieldStringValue = ImageSaver.generateFilename(for: preferredSaveFormat.rawValue)
        } else {
            panel.nameFieldStringValue = ImageSaver.generateFilename(for: preferredSaveFormat.rawValue)
        }
        if panel.runModal() == .OK, let url = panel.url {
            if ImageSaver.writeImage(img, to: url, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                selectedSnipURL = url
                refreshGalleryAfterSaving(to: url)
                reloadCurrentImage()
            }
        }
    }
    
    /// If saved file is within our Snips directory, update the gallery list.
    private func refreshGalleryAfterSaving(to url: URL) {
        if let dir = SnipsDirectory(), url.path.hasPrefix(dir.path) {
            loadExistingSnips()
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
                if shift { current = SnippedPoint(start: start, raw: current) }
                
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
                        if !pushedDragUndo { pushUndoSnipshot(); pushedDragUndo = true }
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
                    end = SnippedPoint(start: s, raw: end)
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
                    pushUndoSnipshot()
                    objects.append(.line(new))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = new.id
                } else if let s = dragStartPoint {
                    let new = LineObject(start: s, end: end, width: strokeWidth, arrow: lineHasArrow, color: lineColor)
                    pushUndoSnipshot()
                    objects.append(.line(new))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = new.id
                }
            }
    }
    
    @inline(__always)
    private func normalizedAngleDelta(from a: CGFloat, to b: CGFloat) -> CGFloat {
        var d = b - a
        let twoPi = CGFloat.pi * 2
        // Wrap into [-π, π]
        if d > .pi {
            d -= twoPi
        } else if d < -.pi {
            d += twoPi
        }
        return d
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
                        if !pushedDragUndo { pushUndoSnipshot(); pushedDragUndo = true }
                        switch objects[idx] {
                        case .rect(let o):
                            var updated = o
                            if activeHandle == .none {
                                updated = o.moved(by: delta)
                            } else if activeHandle == .rotate {
                                // Absolute-angle rotation anchored at gesture begin; no per-tick anchor drift
                                let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

                                // Initialize anchors on first rotate tick for this drag
                                if rectRotateStartAngle == nil || rectRotateStartValue == nil {
                                    // Use the initial dragStartPoint as the pointer anchor at mouse-down
                                    if let s = dragStartPoint {
                                        rectRotateStartAngle = atan2(s.y - c.y, s.x - c.x)
                                    } else {
                                        rectRotateStartAngle = atan2(current.y - c.y, current.x - c.x)
                                    }
                                    rectRotateStartValue = o.rotation
                                }

                                guard let startAngle = rectRotateStartAngle, let baseRotation = rectRotateStartValue else {
                                    return
                                }

                                // Current pointer angle
                                let currAngle = atan2(current.y - c.y, current.x - c.x)

                                // Absolute target = base rotation + delta from initial pointer angle to current pointer angle
                                var target = baseRotation + normalizedAngleDelta(from: startAngle, to: currAngle)

                                // Modifier-based snapping: Option=1°, Command=5°, Shift=15°; none=free
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.option) {
                                    let inc = CGFloat.pi / 180 // 1°
                                    target = round(target / inc) * inc
                                } else if mods.contains(.command) {
                                    let inc = CGFloat.pi / 36 // 5°
                                    target = round(target / inc) * inc
                                } else if mods.contains(.shift) {
                                    let inc = CGFloat.pi / 12 // 15°
                                    target = round(target / inc) * inc
                                }

                                updated.rotation = target

                                // Do NOT clamp rect while rotating; geometry doesn't change
                                objects[idx] = .rect(updated)
                                // Important: keep anchors stable; do not mutate dragStartPoint here
                                return
                            } else {
                                updated = o.resizing(activeHandle, to: current)
                            }
                            if updated.rotation == 0 {
                                let clamped = clampRect(updated.rect, in: author)
                                updated.rect = clamped
                            }
                            objects[idx] = .rect(updated)
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
                
                // Reset rotation anchors (for Rect) - same as pointer tool
                rectRotateStartAngle = nil
                rectRotateStartValue = nil
                
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
                    let newObj = RectObject(rect: clamped, width: strokeWidth, color: rectColor)
                    pushUndoSnipshot()
                    objects.append(.rect(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                } else {
                    // on simple click with no drag, create a default-sized square
                    let d: CGFloat = 40
                    let rect = CGRect(x: max(0, pEnd.x - d/2), y: max(0, pEnd.y - d/2), width: d, height: d)
                    let clamped = clampRect(rect, in: author)
                    let newObj = RectObject(rect: clamped, width: strokeWidth, color: rectColor)
                    pushUndoSnipshot()
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
                        if !pushedDragUndo { pushUndoSnipshot(); pushedDragUndo = true }
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
                    pushUndoSnipshot()
                    objects.append(.oval(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                } else {
                    let d: CGFloat = 40
                    let rect = CGRect(x: max(0, pEnd.x - d/2), y: max(0, pEnd.y - d/2), width: d, height: d)
                    let clamped = clampRect(rect, in: author)
                    let newObj = OvalObject(rect: clamped, width: strokeWidth, color: ovalColor)  // Pass current color
                    pushUndoSnipshot()
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
                        if !pushedDragUndo { pushUndoSnipshot(); pushedDragUndo = true }
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
                    pushUndoSnipshot()
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
                    pushUndoSnipshot()
                    objects.append(.highlight(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                }
            }
    }
    
    // Add these state variables at the top of ContentView with the other rotation anchors
    @State private var textRotateStartAngle: CGFloat? = nil
    @State private var textRotateStartValue: CGFloat? = nil

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
                            pushUndoSnipshot()
                            pushedDragUndo = true
                        }
                        switch objects[idx] {
                        case .text(let o):
                            var updated = o
                            if activeHandle == .none {
                                updated = o.moved(by: delta)
                            } else if activeHandle == .rotate {
                                // Absolute-angle rotation anchored at gesture begin; no per-tick anchor drift
                                let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

                                // Initialize anchors on first rotate tick for this drag
                                if textRotateStartAngle == nil || textRotateStartValue == nil {
                                    // Use the initial dragStartPoint as the pointer anchor at mouse-down
                                    if let s = dragStartPoint {
                                        textRotateStartAngle = atan2(s.y - c.y, s.x - c.x)
                                    } else {
                                        textRotateStartAngle = atan2(p.y - c.y, p.x - c.x)
                                    }
                                    textRotateStartValue = o.rotation
                                }

                                guard let startAngle = textRotateStartAngle, let baseRotation = textRotateStartValue else {
                                    return
                                }

                                // Current pointer angle
                                let currAngle = atan2(p.y - c.y, p.x - c.x)

                                // Absolute target = base rotation + delta from initial pointer angle to current pointer angle
                                var target = baseRotation + normalizedAngleDelta(from: startAngle, to: currAngle)

                                // Modifier-based snapping: Option=1°, Command=5°, Shift=15°; none=free
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.option) {
                                    let inc = CGFloat.pi / 180 // 1°
                                    target = round(target / inc) * inc
                                } else if mods.contains(.command) {
                                    let inc = CGFloat.pi / 36 // 5°
                                    target = round(target / inc) * inc
                                } else if mods.contains(.shift) {
                                    let inc = CGFloat.pi / 12 // 15°
                                    target = round(target / inc) * inc
                                }

                                updated.rotation = target

                                // Do NOT clamp rect while rotating; geometry doesn't change
                                objects[idx] = .text(updated)
                                // Important: keep anchors stable; do not mutate dragStartPoint here
                                return
                            } else {
                                updated = o.resizing(activeHandle, to: p)
                            }
                            let clamped = clampRect(updated.rect, in: author)
                            updated.rect = clamped
                            objects[idx] = .text(updated)
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
                
                // Reset rotation anchors (for Text) - same as pointer and rect tools
                textRotateStartAngle = nil
                textRotateStartValue = nil
                
                if moved {
                    // We were dragging — finish and clean up
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
                    let defaultSize = CGSize(width: textFontSize * 4,   // 4 characters worth
                                            height: textFontSize * 1.5)
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
                    pushUndoSnipshot()
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
    
    
    // Rotation gesture anchors for Rect (keep one anchor per drag)
    @State private var rectRotateStartAngle: CGFloat? = nil
    @State private var rectRotateStartValue: CGFloat? = nil
    @State private var imageRotateStartAngle: CGFloat? = nil
    @State private var imageRotateStartValue: CGFloat? = nil

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
                        pushUndoSnipshot()
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
                        var updated = o
                        if activeHandle == .none {
                            updated = o.moved(by: delta)
                        } else if activeHandle == .rotate {
                            // Absolute-angle rotation anchored at gesture begin; no per-tick anchor drift
                            let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

                            // Initialize anchors on first rotate tick for this drag
                            if rectRotateStartAngle == nil || rectRotateStartValue == nil {
                                // Use the initial dragStartPoint as the pointer anchor at mouse-down
                                if let s = dragStartPoint {
                                    rectRotateStartAngle = atan2(s.y - c.y, s.x - c.x)
                                } else {
                                    rectRotateStartAngle = atan2(p.y - c.y, p.x - c.x)
                                }
                                rectRotateStartValue = o.rotation
                            }

                            guard let startAngle = rectRotateStartAngle, let baseRotation = rectRotateStartValue else {
                                return
                            }

                            // Current pointer angle
                            let currAngle = atan2(p.y - c.y, p.x - c.x)

                            // Absolute target = base rotation + delta from initial pointer angle to current pointer angle
                            var target = baseRotation + normalizedAngleDelta(from: startAngle, to: currAngle)

                            // Modifier-based snapping: Option=1°, Command=5°, Shift=15°; none=free
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.option) {
                                let inc = CGFloat.pi / 180 // 1°
                                target = round(target / inc) * inc
                            } else if mods.contains(.command) {
                                let inc = CGFloat.pi / 36 // 5°
                                target = round(target / inc) * inc
                            } else if mods.contains(.shift) {
                                let inc = CGFloat.pi / 12 // 15°
                                target = round(target / inc) * inc
                            }

                            updated.rotation = target

                            // Do NOT clamp rect while rotating; geometry doesn't change
                            objects[idx] = .rect(updated)
                            // Important: keep anchors stable; do not mutate dragStartPoint here
                            return
                        } else {
                            updated = o.resizing(activeHandle, to: p)
                        }
                        if updated.rotation == 0 {
                            let clamped = clampRect(updated.rect, in: author)
                            updated.rect = clamped
                        }
                        objects[idx] = .rect(updated)
                    case .oval(let o):
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: p)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .oval(u)
                    case .text(let o):
                        var updated = o
                        if activeHandle == .none {
                            updated = o.moved(by: delta)
                        } else if activeHandle == .rotate {
                            // Absolute-angle rotation anchored at gesture begin; no per-tick anchor drift
                            let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

                            // Initialize anchors on first rotate tick for this drag
                            if textRotateStartAngle == nil || textRotateStartValue == nil {
                                // Use the initial dragStartPoint as the pointer anchor at mouse-down
                                if let s = dragStartPoint {
                                    textRotateStartAngle = atan2(s.y - c.y, s.x - c.x)
                                } else {
                                    textRotateStartAngle = atan2(p.y - c.y, p.x - c.x)
                                }
                                textRotateStartValue = o.rotation
                            }

                            guard let startAngle = textRotateStartAngle, let baseRotation = textRotateStartValue else {
                                return
                            }

                            // Current pointer angle
                            let currAngle = atan2(p.y - c.y, p.x - c.x)

                            // Absolute target = base rotation + delta from initial pointer angle to current pointer angle
                            var target = baseRotation + normalizedAngleDelta(from: startAngle, to: currAngle)

                            // Modifier-based snapping: Option=1°, Command=5°, Shift=15°; none=free
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.option) {
                                let inc = CGFloat.pi / 180 // 1°
                                target = round(target / inc) * inc
                            } else if mods.contains(.command) {
                                let inc = CGFloat.pi / 36 // 5°
                                target = round(target / inc) * inc
                            } else if mods.contains(.shift) {
                                let inc = CGFloat.pi / 12 // 15°
                                target = round(target / inc) * inc
                            }

                            updated.rotation = target

                            objects[idx] = .text(updated)
                            // Important: keep anchors stable; do not mutate dragStartPoint here
                            return
                        } else {
                            updated = o.resizing(activeHandle, to: p)
                        }
                        let clamped = clampRect(updated.rect, in: author)
                        updated.rect = clamped
                        objects[idx] = .text(updated)
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
                        var updated = o
                        if activeHandle == .none {
                            updated = o.moved(by: delta)
                        } else if activeHandle == .rotate {
                            // Absolute-angle rotation anchored at gesture begin; no per-tick anchor drift
                            let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

                            // Initialize anchors on first rotate tick for this drag
                            if imageRotateStartAngle == nil || imageRotateStartValue == nil {
                                if let s = dragStartPoint {
                                    imageRotateStartAngle = atan2(s.y - c.y, s.x - c.x)
                                } else {
                                    imageRotateStartAngle = atan2(p.y - c.y, p.x - c.x)
                                }
                                imageRotateStartValue = o.rotation
                            }

                            guard let startAngle = imageRotateStartAngle, let baseRotation = imageRotateStartValue else {
                                return
                            }

                            // Current pointer angle
                            let currAngle = atan2(p.y - c.y, p.x - c.x)

                            // Absolute target = base rotation + delta from initial pointer angle to current pointer angle
                            var target = baseRotation + normalizedAngleDelta(from: startAngle, to: currAngle)

                            // Modifier-based snapping: Option=1°, Command=5°, Shift=15°; none=free
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.option) {
                                let inc = CGFloat.pi / 180 // 1°
                                target = round(target / inc) * inc
                            } else if mods.contains(.command) {
                                let inc = CGFloat.pi / 36  // 5°
                                target = round(target / inc) * inc
                            } else if mods.contains(.shift) {
                                let inc = CGFloat.pi / 12  // 15°
                                target = round(target / inc) * inc
                            }

                            updated.rotation = target
                            objects[idx] = .image(updated)
                            // Important: keep anchors stable; do not mutate dragStartPoint here
                            return
                        } else {
                            updated = o.resizing(activeHandle, to: p)
                        }
                        let clamped = clampRect(updated.rect, in: author)
                        updated.rect = clamped
                        objects[idx] = .image(updated)
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
                let _ = hypot(dx, dy) > 5

                // Reset rotation anchors (for Rect)
                rectRotateStartAngle = nil
                rectRotateStartValue = nil
                textRotateStartAngle = nil
                textRotateStartValue = nil
                imageRotateStartAngle = nil
                imageRotateStartValue = nil

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
                        if !pushedDragUndo { pushUndoSnipshot(); pushedDragUndo = true }
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
                pushUndoSnipshot()
                objects.append(.badge(newObj))
                if objectSpaceSize == nil { objectSpaceSize = author }
                selectedObjectID = newObj.id
            }
    }
    
    @inline(__always)
    private func fittedToAuthorPoint(_ p: CGPoint, fitted: CGSize, author: CGSize) -> CGPoint {
        let sx = author.width  / max(1, fitted.width)
        let sy = author.height / max(1, fitted.height)
        return CGPoint(x: p.x * sx, y: p.y * sy)
    }
    
    @inline(__always)
    private func normalizeRect(_ r: CGRect) -> CGRect {
        CGRect(x: min(r.minX, r.maxX),
               y: min(r.minY, r.maxY),
               width: abs(r.width),
               height: abs(r.height))
    }
    
    
    private func cropGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 1) Pointer in fitted space (subtract centering inset)
                let locFitted = CGPoint(
                    x: value.location.x - insetOrigin.x,
                    y: value.location.y - insetOrigin.y
                )
                // 2) Clamp to the visible fitted image
                let clampedFitted = CGPoint(
                    x: min(max(0, locFitted.x), fitted.width),
                    y: min(max(0, locFitted.y), fitted.height)
                )
                // 3) Convert to author/object space where overlay lives
                let locAuthor = fittedToAuthorPoint(clampedFitted, fitted: fitted, author: author)
                
                if cropDragStart == nil {
                    // First event of this drag
                    cropDragStart = locAuthor
                    // If we already have a rect, check for handle resize
                    if let existing = cropRect {
                        let handle = cropHandleHitTest(existing, at: locAuthor)
                        if handle != .none {
                            cropHandle = handle
                            cropOriginalRect = existing
                            return
                        }
                    }
                }
                
                if cropHandle != .none, let original = cropOriginalRect {
                    // Resizing existing rect
                    cropRect = normalizeRect(resizeRect(original, handle: cropHandle, to: locAuthor))
                    cropDraftRect = nil
                } else if let start = cropDragStart {
                    // Drafting a new rect during drag
                    cropDraftRect = normalizeRect(CGRect(
                        x: min(start.x, locAuthor.x),
                        y: min(start.y, locAuthor.y),
                        width: abs(locAuthor.x - start.x),
                        height: abs(locAuthor.y - start.y)
                    ))
                }
            }
            .onEnded { _ in
                defer {
                    cropDragStart = nil
                    cropOriginalRect = nil
                    cropHandle = .none
                }
                
                if cropHandle != .none, let updated = cropRect {
                    // Finished a resize — keep normalized
                    cropRect = normalizeRect(updated)
                    cropDraftRect = nil
                    return
                }
                
                if let draft = cropDraftRect {
                    // Commit new rect
                    cropRect = normalizeRect(draft)
                    cropDraftRect = nil
                }
            }
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
    
    @inline(__always)
    private func rotatePoint(_ p: CGPoint, around c: CGPoint, by angle: CGFloat) -> CGPoint {
        let s = sin(angle), co = cos(angle)
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * co - dy * s,
                       y: c.y + dx * s + dy * co)
    }

    private func selectionHandlesForRect(_ o: RectObject) -> some View {
        let rotateOffset: CGFloat = 20
        let c = CGPoint(x: o.rect.midX, y: o.rect.midY)
        
        // Raw unrotated positions
        let rawPts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        let rawRotate = CGPoint(x: o.rect.maxX + rotateOffset, y: o.rect.minY - rotateOffset)
        
        // Rotate positions to match the rotated rectangle
        let pts = rawPts.map { rotatePoint($0, around: c, by: o.rotation) }
        let rotatePos = rotatePoint(rawRotate, around: c, by: o.rotation)
        
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.blue)
                .background(Circle().fill(.white).frame(width: 16, height: 16))
                .position(rotatePos)
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
        let rotateOffset: CGFloat = 20
        let c = CGPoint(x: o.rect.midX, y: o.rect.midY)
        
        // Raw unrotated positions
        let rawPts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        let rawRotate = CGPoint(x: o.rect.maxX + rotateOffset, y: o.rect.minY - rotateOffset)
        
        // Rotate positions to match the rotated text box
        let pts = rawPts.map { rotatePoint($0, around: c, by: o.rotation) }
        let rotatePos = rotatePoint(rawRotate, around: c, by: o.rotation)
        
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
            
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.blue)
                .background(Circle().fill(.white).frame(width: 16, height: 16))
                .position(rotatePos)
            
            // TextEditor for focused text (also needs to be in scaled context with rotation)
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
                .rotationEffect(Angle(radians: o.rotation))
                .position(x: o.rect.midX, y: o.rect.midY)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.blue.opacity(0.6), lineWidth: 1)
                        .rotationEffect(Angle(radians: o.rotation))
                )
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
        let rotateOffset: CGFloat = 20
        let c = CGPoint(x: o.rect.midX, y: o.rect.midY)
        
        // Raw unrotated positions
        let rawPts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        let rawRotate = CGPoint(x: o.rect.maxX + rotateOffset, y: o.rect.minY - rotateOffset)
        
        // Rotate positions to match the rotated image
        let pts = rawPts.map { rotatePoint($0, around: c, by: o.rotation) }
        let rotatePos = rotatePoint(rawRotate, around: c, by: o.rotation)
        
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
            
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.blue)
                .background(Circle().fill(.white).frame(width: 16, height: 16))
                .position(rotatePos)
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
        pushUndoSnipshot()
        if let flattened = rasterize(base: img, objects: objects) {
            objects.removeAll()
            if let url = selectedSnipURL {
                // Write the flattened image back to the same file
                if ImageSaver.writeImage(flattened, to: url, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                    reloadCurrentImage()
                    thumbnailRefreshTrigger = UUID()
                }
            } else {
                saveAsCurrent()
            }
        }
    }
    
    private func flattenAndSaveAs() {
        guard let img = currentImage else { return }
        if objectSpaceSize == nil { objectSpaceSize = lastFittedSize ?? img.size }
        pushUndoSnipshot()
        if let flattened = rasterize(base: img, objects: objects) {
            objects.removeAll()
            exportImage = flattened
            showingFileExporter = true
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
                    o.color.setStroke()
                    
                    if o.rotation != 0 {
                        NSGraphicsContext.current?.saveGraphicsState()
                        
                        // Apply rotation in UI space first, then transform to image space
                        let uiCenter = CGPoint(x: o.rect.midX, y: o.rect.midY)
                        
                        // Create the four corners of the rectangle in UI space
                        let corners = [
                            CGPoint(x: o.rect.minX, y: o.rect.minY),
                            CGPoint(x: o.rect.maxX, y: o.rect.minY),
                            CGPoint(x: o.rect.maxX, y: o.rect.maxY),
                            CGPoint(x: o.rect.minX, y: o.rect.maxY)
                        ]
                        
                        // Rotate corners around center in UI space
                        let rotatedCorners = corners.map { corner in
                            let dx = corner.x - uiCenter.x
                            let dy = corner.y - uiCenter.y
                            let cos = Foundation.cos(o.rotation)
                            let sin = Foundation.sin(o.rotation)
                            return CGPoint(
                                x: uiCenter.x + dx * cos - dy * sin,
                                y: uiCenter.y + dx * sin + dy * cos
                            )
                        }
                        
                        // Transform each rotated corner to image space
                        let imageCorners = rotatedCorners.map {
                            uiToImagePoint($0, fitted: fitted, image: imgSize)
                        }
                        
                        // Draw the rotated rectangle as a polygon
                        let path = NSBezierPath()
                        path.move(to: imageCorners[0])
                        for i in 1..<imageCorners.count {
                            path.line(to: imageCorners[i])
                        }
                        path.close()
                        path.lineWidth = o.width * scaleW
                        path.stroke()
                        
                        NSGraphicsContext.current?.restoreGraphicsState()
                    } else {
                        let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                        let path = NSBezierPath(rect: r)
                        path.lineWidth = o.width * scaleW
                        path.stroke()
                    }
                case .oval(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    o.color.setStroke()
                    let path = NSBezierPath(ovalIn: r)
                    path.lineWidth = o.width * scaleW
                    path.stroke()
                case .text(let o):
                    // For rotated text, we need to work entirely in UI space first, then convert to image space
                    if o.rotation != 0 {
                        NSGraphicsContext.current?.saveGraphicsState()
                        
                        // 1. Get the UI space rect and center
                        let uiRect = o.rect
                        let uiCenter = CGPoint(x: uiRect.midX, y: uiRect.midY)
                        
                        // 2. Convert center to image space
                        let imageCenter = uiToImagePoint(uiCenter, fitted: fitted, image: imgSize)
                        
                        // 3. Convert size to image space (no Y-flip for size)
                        let imageSize = CGSize(
                            width: uiRect.width * (imgSize.width / max(1, fitted.width)),
                            height: uiRect.height * (imgSize.height / max(1, fitted.height))
                        )
                        
                        // 4. Create image rect centered at the converted center
                        let imageRect = CGRect(
                            x: imageCenter.x - imageSize.width / 2,
                            y: imageCenter.y - imageSize.height / 2,
                            width: imageSize.width,
                            height: imageSize.height
                        )
                        
                        // 5. Apply rotation in image space around the image center
                        // Note: Negate the rotation because image Y is flipped from UI Y
                        let transform = NSAffineTransform()
                        transform.translateX(by: imageCenter.x, yBy: imageCenter.y)
                        transform.rotate(byRadians: -o.rotation)  // Negate rotation for flipped coordinate system
                        transform.translateX(by: -imageCenter.x, yBy: -imageCenter.y)
                        transform.concat()
                        
                        // 6. Draw background if enabled
                        if o.bgEnabled {
                            let paddingScaled = 4 * scaleW
                            let bgRect = imageRect.insetBy(dx: -paddingScaled, dy: -paddingScaled)
                            let bg = NSBezierPath(rect: bgRect)
                            o.bgColor.setFill()
                            bg.fill()
                        }
                        
                        // 7. Draw text
                        let para = NSMutableParagraphStyle()
                        para.alignment = .left
                        para.lineBreakMode = .byWordWrapping
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: o.fontSize * scaleW),
                            .foregroundColor: o.textColor,
                            .paragraphStyle: para
                        ]
                        
                        NSString(string: o.text).draw(in: imageRect, withAttributes: attrs)
                        
                        NSGraphicsContext.current?.restoreGraphicsState()
                    } else {
                        // Non-rotated text - use existing logic
                        let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                        let paddingScaled = 4 * scaleW
                        
                        // Draw background with proper padding to match SwiftUI rendering
                        if o.bgEnabled {
                            let bgRect = r.insetBy(dx: -paddingScaled, dy: -paddingScaled)
                            let bg = NSBezierPath(rect: bgRect)
                            o.bgColor.setFill()
                            bg.fill()
                        }
                        
                        // Draw text
                        let para = NSMutableParagraphStyle()
                        para.alignment = .left
                        para.lineBreakMode = .byWordWrapping
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: o.fontSize * scaleW),
                            .foregroundColor: o.textColor,
                            .paragraphStyle: para
                        ]
                        
                        NSString(string: o.text).draw(in: r, withAttributes: attrs)
                    }
                case .badge(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    
                    // Draw the circle background
                    let circle = NSBezierPath(ovalIn: r)
                    o.fillColor.setFill()
                    circle.fill()
                    
                    // Calculate font size
                    let fontSize = min(r.width, r.height) * 0.6
                    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
                    
                    // Create attributed string
                    let numberString = "\(o.number)"
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: o.textColor
                    ]
                    let attributedString = NSAttributedString(string: numberString, attributes: attrs)
                    
                    // Calculate text size and center it manually
                    let textSize = attributedString.size()
                    let textRect = CGRect(
                        x: r.midX - textSize.width / 2,
                        y: r.midY - textSize.height / 2,
                        width: textSize.width,
                        height: textSize.height
                    )
                    
                    // Draw the text at the calculated position
                    attributedString.draw(in: textRect)
                case .highlight(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    o.color.setFill(); NSBezierPath(rect: r).fill()
                case .image(let o):
                    if o.rotation != 0 {
                        NSGraphicsContext.current?.saveGraphicsState()
                        
                        // 1. Get the UI space rect and center
                        let uiRect = o.rect
                        let uiCenter = CGPoint(x: uiRect.midX, y: uiRect.midY)
                        
                        // 2. Convert center to image space
                        let imageCenter = uiToImagePoint(uiCenter, fitted: fitted, image: imgSize)
                        
                        // 3. Convert size to image space (no Y-flip for size)
                        let imageSize = CGSize(
                            width: uiRect.width * (imgSize.width / max(1, fitted.width)),
                            height: uiRect.height * (imgSize.height / max(1, fitted.height))
                        )
                        
                        // 4. Create image rect centered at the converted center
                        let imageRect = CGRect(
                            x: imageCenter.x - imageSize.width / 2,
                            y: imageCenter.y - imageSize.height / 2,
                            width: imageSize.width,
                            height: imageSize.height
                        )
                        
                        // 5. Apply rotation in image space around the image center
                        // Note: Negate the rotation because image Y is flipped from UI Y
                        let transform = NSAffineTransform()
                        transform.translateX(by: imageCenter.x, yBy: imageCenter.y)
                        transform.rotate(byRadians: -o.rotation)  // Negate rotation for flipped coordinate system
                        transform.translateX(by: -imageCenter.x, yBy: -imageCenter.y)
                        transform.concat()
                        
                        // 6. Draw the image
                        o.image.draw(in: imageRect)
                        
                        NSGraphicsContext.current?.restoreGraphicsState()
                    } else {
                        // Non-rotated image - use existing logic
                        let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                        o.image.draw(in: r)
                    }
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
        pushUndoSnipshot()
        objects.remove(at: idx)
        selectedObjectID = nil
        activeHandle = .none
    }
    
    private func performUndo() {
        guard let prev = undoStack.popLast() else { return }
        let current = Snipshot(imageURL: selectedSnipURL, objects: objects)
        redoStack.append(current)
        selectedSnipURL = prev.imageURL  // Just change the URL
        objects = prev.objects
        
        updateMenuState()
        
    }
    
    private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        let current = Snipshot(imageURL: selectedSnipURL, objects: objects)
        undoStack.append(current)
        selectedSnipURL = next.imageURL  // Just change the URL
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
    
    // Shift Snipping for straight lines at 0°/45°/90°
    private func SnippedPoint(start: CGPoint, raw: CGPoint) -> CGPoint {
        let dx = raw.x - start.x
        let dy = raw.y - start.y
        let adx = abs(dx)
        let ady = abs(dy)
        if adx == 0 && ady == 0 { return raw }
        // Thresholds for 22.5° and 67.5° to decide Snipping band
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
            pushUndoSnipshot()
            objects.append(.image(obj))
            if objectSpaceSize == nil { objectSpaceSize = author }
            selectedObjectID = obj.id
            activeHandle = .none
            // no focus change for text
        }
    }
    
    // MARK: - Snips Persistence
    
    private func SnipsDirectory() -> URL? {
        // If the user has chosen a custom destination, resolve from bookmark
        if !saveDirectoryPath.isEmpty {
            if let bookmarkData = UserDefaults.standard.data(forKey: "saveDirectoryBookmark") {
                do {
                    var isStale = false
                    let url = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    
                    guard url.startAccessingSecurityScopedResource() else {
                        print("Failed to access security-scoped resource")
                        return defaultSnipsDirectory()
                    }
                    
                    // Store a reference to stop accessing later if needed
                    // You might want to manage this lifecycle better
                    return url
                    
                } catch {
                    print("Failed to resolve bookmark: \(error)")
                    // Fall back to default directory
                    return defaultSnipsDirectory()
                }
            }
        }
        
        return defaultSnipsDirectory()
    }

    private func defaultSnipsDirectory() -> URL? {
        let fm = FileManager.default
        if let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
            let dir = pictures.appendingPathComponent("Screen Snip", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        return nil
    }
    
    private var currentImage: NSImage? {
        guard let url = selectedSnipURL else { return nil }
        return NSImage(contentsOf: url)  // Load on-demand
    }
    
    /// Loads existing Snips on disk (all supported formats), newest first.
    private func loadExistingSnips() {
        guard let dir = SnipsDirectory() else { return }
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
            SnipURLs = Array(sorted.prefix(10))
            
            // Clean up missing URLs from our tracking set
            missingSnipURLs = missingSnipURLs.filter { !sorted.contains($0) }
            
            // If currently selected Snip no longer exists, clear selection
            if let sel = selectedSnipURL {
                if !fm.fileExists(atPath: sel.path) {
                    selectedSnipURL = nil
                }
            }
        } catch {
            SnipURLs = []
        }
    }
    
    /// Opens the Snips directory in Finder as a simple "gallery" view.
    private func openSnipsInFinder() {
        guard let dir = SnipsDirectory() else { return }
        NSWorkspace.shared.open(dir)
    }
    
    private func openSnipsInGallery() {
        guard let dir = SnipsDirectory() else { return }
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
                    // File is missing - add to missing set and remove from SnipURLs
                    missingSnipURLs.insert(url)
                    if let index = SnipURLs.firstIndex(of: url) {
                        SnipURLs.remove(at: index)
                    }
                    return
                }
                
                // File exists - load it into the editor using the same logic as the main thumbnail view
                selectedSnipURL = url
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
                guard let dir = SnipsDirectory() else { return [] }
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
    private func insertSnipURL(_ url: URL) {
        if let idx = SnipURLs.firstIndex(of: url) {
            SnipURLs.remove(at: idx)
        }
        SnipURLs.insert(url, at: 0)
    }
    
    /// Delete a Snip from disk and update gallery/selection.
    private func deleteSnip(_ url: URL) {
        let fm = FileManager.default
        // Prefer moving to Trash; fall back to remove.
        do {
            var trashedURL: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashedURL)
        } catch {
            try? fm.removeItem(at: url)
        }
        // Update gallery list
        if let idx = SnipURLs.firstIndex(of: url) {
            SnipURLs.remove(at: idx)
        }
        // Update current selection / preview
        if selectedSnipURL == url {
            selectedSnipURL = SnipURLs.first
            if let sel = selectedSnipURL {
                selectedImageSize = probeImageSize(sel)
                lastFittedSize = nil
            } else {
                selectedImageSize = nil
                lastFittedSize = nil
            }
        }
    }
    
    func cropImage(_ image: NSImage, toBottomLeftRect rBL: CGRect) -> NSImage? {
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
    
}




