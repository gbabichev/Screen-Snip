


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


enum Tool { case pointer, line, rect, oval, text, crop, badge, highlighter, blur }

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
    
    @ObservedObject var appDelegate = AppDelegate.shared
    
    @FocusState private var thumbnailsFocused: Bool

    // Zoom
    
    let ZOOM_MIN: Double = 0.5
    let ZOOM_MAX: Double = 3.0
    
    
    
    
    var hasPermissionIssues: Bool {
        appDelegate.needsAccessibilityPermission || appDelegate.needsScreenRecordingPermission
    }
    
    var aboutOverlayBinding: Binding<Bool> {
        Binding(
            get: { appDelegate.showAboutOverlay },
            set: { newValue in
                guard appDelegate.showAboutOverlay != newValue else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    appDelegate.showAboutOverlay = newValue
                }
            }
        )
    }
    
    
    // MARK: - Launch On Logon
    static let loginHelperIdentifier = "com.georgebabichev.Screen-Snip-Helper"
    @State var logonChecked: Bool = {
        let loginService = SMAppService.loginItem(identifier: loginHelperIdentifier)
        return loginService.status == .enabled   // True if login item is currently enabled
    }()
    
    // MARK: - Vars
    @Environment(\.openWindow) var openWindow  // Add this line
    @State var showingFileExporter = false
    @State var exportImage: NSImage? = nil
    
    @AppStorage("captureMode") var captureModeRaw: String = CaptureMode.captureWithWindows.rawValue

    
    @State var currentGeometrySize: CGSize = CGSize(width: 800, height: 600)
    
    
    @State var thumbnailRefreshTrigger = UUID()
    
    @State var selectedImageSize: CGSize? = nil
    @State var imageReloadTrigger = UUID()
    @State var missingSnipURLs: Set<URL> = []
    @State var zoomLevel: Double = 1.0
    @State var pinchBaseZoom: Double? = nil
    
    @State var showSettingsPopover = false
    @AppStorage("preferredSaveFormat") var preferredSaveFormatRaw: String = SaveFormat.png.rawValue
    var preferredSaveFormat: SaveFormat {
        get { SaveFormat(rawValue: preferredSaveFormatRaw) ?? .png }
        set { preferredSaveFormatRaw = newValue.rawValue }
    }
    
    @AppStorage("hideDockIcon") var hideDockIcon: Bool = false
    @AppStorage("saveQuality") var saveQuality: Double = 0.9
    @AppStorage("saveDirectoryPath") var saveDirectoryPath: String = ""
    @AppStorage("downsampleToNonRetinaClipboard") var downsampleToNonRetinaClipboard: Bool = true
    @AppStorage("downsampleToNonRetinaForSave") var downsampleToNonRetinaForSave: Bool = false
    @AppStorage("imageDisplayMode") var imageDisplayMode: String = "fit" // "actual" or "fit"
    @AppStorage("saveOnCopy") var saveOnCopy: Bool = false
    
    
    enum ImporterKind { case image, folder }
    @State var activeImporter: ImporterKind? = nil
    
    @FocusState var isTextEditorFocused: Bool
    
    @State var focusedTextID: UUID? = nil
    @State var showCopiedHUD = false
    @State var selectedTool: Tool = .pointer
    // Removed lines buffer; we now auto-commit each line on mouse-up.
    @State var draft: Line? = nil
    @State var draftRect: CGRect? = nil
    @State var cropDraftRect: CGRect? = nil
    @State var cropRect: CGRect? = nil
    @State var cropHandle: Handle = .none
    @State var cropDragStart: CGPoint? = nil
    @State var cropOriginalRect: CGRect? = nil
    @AppStorage("strokeWidth") var strokeWidth: Double = 3
    @AppStorage("blurAmount") var blurAmount: Double = 8
    @AppStorage("lineColor") var lineColorRaw: String = "#000000FF"
    var lineColor: NSColor {
        get { NSColor(hexRGBA: lineColorRaw) ?? .black }
        set { lineColorRaw = newValue.toHexRGBA() }
    }
    var lineColorBinding: Binding<NSColor> {
        Binding(
            get: { lineColor },
            set: { newValue in
                lineColorRaw = newValue.toHexRGBA()
            }
        )
    }
    @AppStorage("rectColor") var rectColorRaw: String = "#000000FF"
    var rectColor: NSColor {
        get { NSColor(hexRGBA: rectColorRaw) ?? .black }
        set { rectColorRaw = newValue.toHexRGBA() }
    }
    var rectColorBinding: Binding<NSColor> {
        Binding(
            get: { rectColor },
            set: { newValue in rectColorRaw = newValue.toHexRGBA() }
        )
    }
    @AppStorage("ovalColor") var ovalColorRaw: String = "#000000FF"
    var ovalColor: NSColor {
        get { NSColor(hexRGBA: ovalColorRaw) ?? .black }
        set { ovalColorRaw = newValue.toHexRGBA() }
    }
    var ovalColorBinding: Binding<NSColor> {
        Binding(
            get: { ovalColor },
            set: { newValue in ovalColorRaw = newValue.toHexRGBA() }
        )
    }
    @State var lineHasArrow: Bool = false
    // Snips persisted on disk (newest first). Each element is a file URL to a PNG.
    @State var SnipURLs: [URL] = []
    @State var selectedSnipURL: URL? = nil
    @State var objects: [Drawable] = []
    @State var selectedObjectID: UUID? = nil
    @State var selectedObjectIDs: Set<UUID> = [] // Multi-selection support
    @State var selectionRect: CGRect? = nil // Rectangle selection for pointer tool
    @State var selectionDragStart: CGPoint? = nil // Start point for selection rectangle
    @State var activeHandle: Handle = .none
    @State var dragStartPoint: CGPoint? = nil
    
    // Undo/Redo stacks of full images and overlays (save-in-place, memory-bounded by user behavior)
    struct Snipshot {
        let imageURL: URL?
        let objects: [Drawable]
    }
    
    @State var undoStack: [Snipshot] = []
    @State var redoStack: [Snipshot] = []
    @State var pushedDragUndo = false
    @State var keyMonitor: Any? = nil
    
    @AppStorage("textFontSize") var textFontSize: Double = 18
    
    @AppStorage("textColor") var textColorRaw: String = "#000000FF"
    var textColor: NSColor {
        get { NSColor(hexRGBA: textColorRaw) ?? .black }
        set { textColorRaw = newValue.toHexRGBA() }
    }
    var textColorBinding: Binding<NSColor> {
        Binding(get: { textColor }, set: { textColorRaw = $0.toHexRGBA() })
    }
    
    @AppStorage("textBGEnabled") var textBGEnabled: Bool = false

    
    @AppStorage("textBGColor") var textBGColorRaw: String = "#00000099"
    var textBGColor: NSColor {
        get { NSColor(hexRGBA: textBGColorRaw) ?? NSColor.black.withAlphaComponent(0.6) }
        set { textBGColorRaw = newValue.toHexRGBA() }
    }
    var textBGColorBinding: Binding<NSColor> {
        Binding(get: { textBGColor }, set: { textBGColorRaw = $0.toHexRGBA() })
    }
    
    @AppStorage("badgeColor") var badgeColorRaw: String = "#FF0000FF"
    var badgeColor: NSColor {
        get { NSColor(hexRGBA: badgeColorRaw) ?? .red }
        set { badgeColorRaw = newValue.toHexRGBA() }
    }
    var badgeColorBinding: Binding<NSColor> {
        Binding(get: { badgeColor }, set: { badgeColorRaw = $0.toHexRGBA() })
    }
    
    @State var badgeCount: Int = 0
    
    @AppStorage("highlighterColor") var highlighterColorRaw: String = NSColor.systemYellow.withAlphaComponent(0.35).toHexRGBA()
    var highlighterColor: NSColor {
        get { NSColor(hexRGBA: highlighterColorRaw) ?? NSColor.systemYellow.withAlphaComponent(0.35) }
        set { highlighterColorRaw = newValue.toHexRGBA() }
    }
    var highlighterColorBinding: Binding<NSColor> {
        Binding(get: { highlighterColor }, set: { highlighterColorRaw = $0.toHexRGBA() })
    }
    
    @State var lastFittedSize: CGSize? = nil
    @State var objectSpaceSize: CGSize? = nil  // tracks the UI coordinate space size the objects are authored in

    // Cache of pixelated images for blur objects
    @State var blurSnapshots: [UUID: NSImage] = [:]

    @State var lastDraftTick: CFTimeInterval = 0
    
    @State var lastTextEditDoubleClickAt: CFTimeInterval = 0
    
    // Throttle rapid draft updates to ~90 Hz (for drag gestures)
    func allowDraftTick(interval: Double = 1.0/90.0) -> Bool {
        let now = CACurrentMediaTime()
        if now - lastDraftTick < interval { return false }
        lastDraftTick = now
        return true
    }
    
    func getActualDisplaySize(_ pixelSize: CGSize) -> CGSize {
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
    
    func authorRectToPixelBL(
        authorRect: CGRect,
        baseImage: NSImage,
        selectedImageSize: CGSize?,
        imageDisplayMode: String,
        currentGeometrySize: CGSize,
        objectSpaceSize: CGSize?
    ) -> (pixelBL: CGRect, fittedPointsRect: CGRect) {
        let actualDisplay = getActualDisplaySize(selectedImageSize ?? baseImage.size)
        let fittedForUI: CGSize = (imageDisplayMode == "fit")
            ? fittedImageSize(original: actualDisplay, in: currentGeometrySize)
            : actualDisplay

        // author space -> fitted points
        let authorSpace = objectSpaceSize ?? fittedForUI
        let sx = fittedForUI.width  / max(authorSpace.width,  1)
        let sy = fittedForUI.height / max(authorSpace.height, 1)

        let rectInFittedPoints = CGRect(
            x: authorRect.origin.x * sx,
            y: authorRect.origin.y * sy,
            width: authorRect.width * sx,
            height: authorRect.height * sy
        )

        // fitted points -> pixel (bottom-left origin)
        let pxSize = pixelSize(of: baseImage)
        let pixelBL = fittedRectToImageBottomLeftRect(
            crpRect: rectInFittedPoints,
            fitted: fittedForUI,
            imagePx: pxSize
        )

        return (pixelBL, rectInFittedPoints)
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
                                                        .padding(.horizontal, TextObject.halfHorizontalPadding)
                                                        .padding(.vertical, TextObject.halfVerticalPadding)
                                                        .frame(width: o.rect.width, height: o.rect.height, alignment: .topLeading)
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
                                            case .blur(let o):
                                                // Show pixelated snapshot if available, otherwise show placeholder
                                                if let snapshot = blurSnapshots[o.id] {
                                                    Image(nsImage: snapshot)
                                                        .resizable()
                                                        .interpolation(.none)
                                                        .frame(width: o.rect.width, height: o.rect.height)
                                                        .rotationEffect(Angle(radians: o.rotation))
                                                        .position(x: o.rect.midX, y: o.rect.midY)
                                                } else {
                                                    // Placeholder while snapshot is being generated
                                                    o.drawPath(in: author)
                                                        .fill(Color.white.opacity(0.5))
                                                    o.drawPath(in: author)
                                                        .stroke(Color.gray,
                                                                style: StrokeStyle(lineWidth: 2, dash: [4,4]))
                                                }
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
                                            case .blur(let o): selectionHandlesForBlur(o)
                                            }
                                        }

                                        // Multi-selection indicators
                                        if !selectedObjectIDs.isEmpty {
                                            ForEach(Array(selectedObjectIDs), id: \.self) { objID in
                                                if let idx = objects.firstIndex(where: { $0.id == objID }) {
                                                    // Draw a blue highlight around selected objects
                                                    switch objects[idx] {
                                                    case .line(let o):
                                                        let minX = min(o.start.x, o.end.x) - 5
                                                        let maxX = max(o.start.x, o.end.x) + 5
                                                        let minY = min(o.start.y, o.end.y) - 5
                                                        let maxY = max(o.start.y, o.end.y) + 5
                                                        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                                                        Rectangle().path(in: bounds)
                                                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2))
                                                    case .rect(let o):
                                                        Rectangle().path(in: o.rect.insetBy(dx: -3, dy: -3))
                                                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2))
                                                    case .oval(let o):
                                                        Ellipse().path(in: o.rect.insetBy(dx: -3, dy: -3))
                                                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2))
                                                    case .text(let o):
                                                        Rectangle().path(in: o.rect.insetBy(dx: -3, dy: -3))
                                                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2))
                                                    case .badge(let o):
                                                        Circle()
                                                            .stroke(Color.blue, lineWidth: 2)
                                                            .frame(width: o.rect.width + 6, height: o.rect.height + 6)
                                                            .position(x: o.rect.midX, y: o.rect.midY)
                                                    case .highlight(let o):
                                                        Rectangle().path(in: o.rect.insetBy(dx: -3, dy: -3))
                                                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2))
                                                    case .image(let o):
                                                        Rectangle().path(in: o.rect.insetBy(dx: -3, dy: -3))
                                                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2))
                                                    case .blur(let o):
                                                        Rectangle().path(in: o.rect.insetBy(dx: -3, dy: -3))
                                                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2))
                                                    }
                                                }
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
                                                    .stroke(Color(nsColor: lineColor).opacity(0.8),
                                                            style: StrokeStyle(lineWidth: strokeWidth, dash: [6,4]))
                                            case .highlighter:
                                                Rectangle().path(in: r).fill(Color(nsColor: highlighterColor))
                                            case .oval:
                                                Ellipse().path(in: r)
                                                    .stroke(Color(nsColor: ovalColor).opacity(0.8),
                                                            style: StrokeStyle(lineWidth: strokeWidth, dash: [6,4]))
                                            case .text:
                                                Rectangle()
                                                    .path(in: r)
                                                    .stroke(Color(nsColor: textColor).opacity(0.85),
                                                            style: StrokeStyle(lineWidth: 1.5, dash: [4,3]))
                                            case .blur:
                                                Rectangle()
                                                    .path(in: r)
                                                    .fill(Color.white.opacity(0.5))
                                                Rectangle()
                                                    .path(in: r)
                                                    .stroke(Color.gray.opacity(0.8),
                                                            style: StrokeStyle(lineWidth: 2, dash: [4,4]))
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

                                        // Selection rectangle for multi-select
                                        if let sr = selectionRect {
                                            Rectangle().path(in: sr)
                                                .stroke(Color.blue.opacity(0.8),
                                                        style: StrokeStyle(lineWidth: 1.5, dash: [4,3]))
                                                .overlay(Rectangle().path(in: sr).fill(Color.blue.opacity(0.1)))
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
                                    .simultaneousGesture(selectedTool == .blur       ? blurGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)

                                    .simultaneousGesture(selectedTool == .pointer    ? pointerGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                    .simultaneousGesture(selectedTool == .line       ? lineGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .rect       ? rectGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .oval       ? ovalGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .text       ? textGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .crop       ? cropGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
                                    .simultaneousGesture(selectedTool == .badge      ? badgeGesture(insetOrigin: origin, fitted: fitted, author: author)   : nil)
                                    .simultaneousGesture(selectedTool == .highlighter ? highlightGesture(insetOrigin: origin, fitted: fitted, author: author): nil)
                                    .simultaneousGesture(selectedTool == .blur       ? blurGesture(insetOrigin: origin, fitted: fitted, author: author)    : nil)
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
                copiedHUDOverlay()
            }
            
            if appDelegate.showAboutOverlay {
                aboutOverlayLayer()
            }
        }
        //.frame(minWidth: 1200, minHeight: 400)
        .safeAreaInset(edge: .bottom) {
            SnipGalleryView(
                snipURLs: $SnipURLs,
                selectedSnipURL: $selectedSnipURL,
                missingSnipURLs: $missingSnipURLs,
                thumbnailsFocus: $thumbnailsFocused,
                thumbnailRefreshTrigger: $thumbnailRefreshTrigger,
                navigateToAdjacentThumbnail: navigateToAdjacentThumbnail,
                loadExistingSnips: loadExistingSnips,
                openSnipsInFinder: openSnipsInFinder,
                openSnipsInGallery: openSnipsInGallery,
                deleteSnip: deleteSnip,
                onSelectSnip: selectSnip,
                onMissingSnip: handleMissingSnip
            )
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
                    if selectedTool == .crop, cropRect != nil || cropDraftRect != nil {
                        cropRect = nil
                        cropDraftRect = nil
                        cropHandle = .none
                        cropDragStart = nil
                        cropOriginalRect = nil
                        activeHandle = .none
                        return nil // consume delete to dismiss crop overlay
                    }
                    if !selectedObjectIDs.isEmpty {
                        deleteMultipleSelectedObjects()
                        return nil // consume so we don't propagate/beep
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
                                    if let savedURL = ImageSaver.writeImageReplacing(cropped, at: url, format: preferredSaveFormat.rawValue, quality: saveQuality) {
                                        // Clear all state and reload the cropped image
                                        objects.removeAll()
                                        lastFittedSize = nil
                                        objectSpaceSize = nil
                                        selectedObjectID = nil
                                        activeHandle = .none
                                        cropRect = nil
                                        cropDraftRect = nil
                                        cropHandle = .none
                                        selectedSnipURL = savedURL
                                        selectedImageSize = probeImageSize(savedURL)
                                        lastFittedSize = nil
                                        imageReloadTrigger = UUID()
                                        zoomLevel = 1.0
                                        refreshGalleryAfterSaving(to: savedURL)
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
            toolbarContent()
        }
        .sheet(isPresented: $appDelegate.showPermissionsView) {
            permissionsSheetContent()
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
                    return ImageSaver.replaceExtension(of: sel.lastPathComponent, with: preferredSaveFormat.rawValue)
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
    

    enum NavigationDirection {
        case previous, next
    }

    func navigateToAdjacentThumbnail(direction: NavigationDirection) {
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
        selectSnip(targetURL)
    }

    func selectSnip(_ url: URL) {
        selectedSnipURL = url
        selectedImageSize = probeImageSize(url)
        updateMenuState()
        objects.removeAll()
        objectSpaceSize = nil
        selectedObjectID = nil
        selectedObjectIDs.removeAll()
        activeHandle = .none
        cropRect = nil
        cropDraftRect = nil
        cropHandle = .none
        focusedTextID = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }
    
    func handleMissingSnip(_ url: URL) {
        if let idx = SnipURLs.firstIndex(of: url) {
            SnipURLs.remove(at: idx)
        }
        if selectedSnipURL == url {
            selectedSnipURL = nil
            updateMenuState()
        }
    }
    

    // MARK: - Launch On Logon Helpers
    // Handles enabling or disabling the login helper at login
    func toggleLaunchAtLogin(_ enabled: Bool) {
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
    
    func showErrorAlert(message: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = message
        if let info = info {
            alert.informativeText = info
        }
        alert.alertStyle = .warning
        alert.runModal()
    }
    func updateMenuState() {
        MenuState.shared.canUndo = !undoStack.isEmpty
        MenuState.shared.canRedo = !redoStack.isEmpty
        MenuState.shared.hasSelectedImage = selectedSnipURL != nil
    }
    
    func reloadCurrentImage() {
        guard let url = selectedSnipURL else { return }
        imageReloadTrigger = UUID()
        selectedImageSize = probeImageSize(url)
        lastFittedSize = nil
    }
        
    func probeImageSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = (props[kCGImagePropertyPixelWidth]  as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return (w > 0 && h > 0) ? CGSize(width: w, height: h) : nil
    }
    
    func pixelSize(of image: NSImage) -> CGSize {
        if let bestRep = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return CGSize(width: bestRep.pixelsWide, height: bestRep.pixelsHigh)
        }
        return CGSize(width: image.size.width, height: image.size.height)
    }
    
    func fittedRectToImageBottomLeftRect(crpRect: CGRect, fitted: CGSize, imagePx: CGSize) -> CGRect {
        let sx = imagePx.width / max(1, fitted.width)
        let sy = imagePx.height / max(1, fitted.height)
        let x = crpRect.origin.x * sx
        let w = crpRect.size.width * sx
        let yTop = crpRect.origin.y * sy
        let h = crpRect.size.height * sy
        let yBL = imagePx.height - (yTop + h)
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
    func handleSelectTool(_ raw: String) {
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
        case "blur":        selectedTool = .blur
        default: break
        }
    }
    
    // Settings - Downsample from Retina
    func isRetinaImage(_ image: NSImage) -> Bool {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return false }
        
        let pointSize = image.size
        let pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        
        let scaleX = pixelSize.width / pointSize.width
        let scaleY = pixelSize.height / pointSize.height
        
        return scaleX > 1.5 || scaleY > 1.5
    }
    
    func downsampleImage(_ image: NSImage) -> NSImage {
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

    /// Generate a pixelated snapshot for a blur object by rendering current state
    func generateBlurSnapshot(for blurObj: BlurRectObject) {
        guard let url = selectedSnipURL else { return }
        guard let base = NSImage(contentsOf: url) else { return }

        let pixelSize = max(1, blurObj.blurRadius)

        // Convert UI rect to image coordinates (same as flatten process)
        let (pixelBL, _) = authorRectToPixelBL(
            authorRect: blurObj.rect,
            baseImage: base,
            selectedImageSize: selectedImageSize,
            imageDisplayMode: imageDisplayMode,
            currentGeometrySize: currentGeometrySize,
            objectSpaceSize: objectSpaceSize
        )

        // Get the base image as CGImage to crop from
        guard let baseCG = base.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        // Convert BL to TL for CGImage cropping (CGImage uses top-left origin)
        let pixelTL = CGRect(
            x: pixelBL.origin.x,
            y: CGFloat(baseCG.height) - pixelBL.origin.y - pixelBL.height,
            width: pixelBL.width,
            height: pixelBL.height
        )

        // Clamp to image bounds
        let rPixels = CGRect(
            x: max(0, pixelTL.origin.x).rounded(.down),
            y: max(0, pixelTL.origin.y).rounded(.down),
            width: min(CGFloat(baseCG.width) - max(0, pixelTL.origin.x), pixelTL.width).rounded(.down),
            height: min(CGFloat(baseCG.height) - max(0, pixelTL.origin.y), pixelTL.height).rounded(.down)
        )

        guard rPixels.width > 0, rPixels.height > 0 else { return }

        // Crop the region from the base image
        guard let cropped = baseCG.cropping(to: rPixels) else { return }

        // Now apply pixelation to the cropped region
        let downsampledWidth = max(1, Int(CGFloat(cropped.width) / pixelSize))
        let downsampledHeight = max(1, Int(CGFloat(cropped.height) / pixelSize))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let downsampleContext = CGContext(
            data: nil,
            width: downsampledWidth,
            height: downsampledHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        downsampleContext.interpolationQuality = CGInterpolationQuality.high
        downsampleContext.draw(cropped, in: CGRect(x: 0, y: 0, width: downsampledWidth, height: downsampledHeight))

        guard let downsampledImage = downsampleContext.makeImage() else { return }

        guard let upsampleContext = CGContext(
            data: nil,
            width: cropped.width,
            height: cropped.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        upsampleContext.interpolationQuality = CGInterpolationQuality.none
        upsampleContext.draw(downsampledImage, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))

        guard let pixelatedCGImage = upsampleContext.makeImage() else { return }

        let pixelatedNSImage = NSImage(cgImage: pixelatedCGImage, size: blurObj.rect.size)

        // Update the cache
        blurSnapshots[blurObj.id] = pixelatedNSImage
    }



    func cropHandleHitTest(_ rect: CGRect, at p: CGPoint) -> Handle {
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
    
    func resizeRect(_ rect: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
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
    
    func copyToPasteboard(_ image: NSImage) {
        // Capture necessary state
        let objectsSnapshot = objects
        let saveOnCopy = UserDefaults.standard.bool(forKey: "saveOnCopy")
        let selectedURL = selectedSnipURL
        let format = preferredSaveFormat.rawValue
        let quality = saveQuality
        let downsampleSetting = downsampleToNonRetinaClipboard

        // Move heavy image processing to .utility thread to avoid priority inversion
        DispatchQueue.global(qos: .utility).async {
            // 1) ALWAYS flatten first so annotations are included
            let flattened: NSImage = {
                // Use DispatchQueue.main.sync to safely call main-actor methods
                return DispatchQueue.main.sync {
                    if let f = self.rasterize(base: image, objects: objectsSnapshot) { return f }
                    return image // graceful fallback
                }
            }()

            // 2) Respect user toggle: only downsample if requested AND the image is retina
            let shouldDownsample = DispatchQueue.main.sync { downsampleSetting && self.isRetinaImage(flattened) }
            let source: NSImage = shouldDownsample ? DispatchQueue.main.sync { self.downsampleImage(flattened) } : flattened

            // 3) Generate PNG data on utility thread
            var pngData: Data?
            let bestRep = source.representations
                .compactMap { $0 as? NSBitmapImageRep }
                .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })

            if let cg = bestRep?.cgImage ?? source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let rep = NSBitmapImageRep(cgImage: cg)
                pngData = rep.representation(using: .png, properties: [:])
            }

            // 4) Update pasteboard on main thread (required for pasteboard operations)
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()

                if let data = pngData {
                    pb.setData(data, forType: .png)
                } else {
                    pb.writeObjects([source])
                }

                // Show HUD after pasteboard is updated
                withAnimation { self.showCopiedHUD = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation { self.showCopiedHUD = false }
                }
            }

            // 5) Optional: Save the rasterized image to disk when enabled in settings
            if saveOnCopy {
                if let url = selectedURL {
                    if let savedURL = ImageSaver.writeImageReplacing(source, at: url, format: format, quality: quality, preserveAttributes: true) {
                        DispatchQueue.main.async {
                            // Clear all drawn objects after successful save
                            self.objects.removeAll()
                            self.selectedObjectID = nil
                            self.activeHandle = .none
                            self.focusedTextID = nil
                            self.cropRect = nil
                            self.cropDraftRect = nil
                            self.cropHandle = .none
                            self.selectedSnipURL = savedURL
                            self.refreshGalleryAfterSaving(to: savedURL)
                            self.reloadCurrentImage()
                        }
                    }
                } else {
                    DispatchQueue.main.sync {
                        if let dir = self.SnipsDirectory() {
                            let newName = ImageSaver.generateFilename(for: format)
                            let dest = dir.appendingPathComponent(newName)
                            DispatchQueue.global(qos: .utility).async {
                                if ImageSaver.writeImage(source, to: dest, format: format, quality: quality, preserveAttributes: true) {
                                    DispatchQueue.main.async {
                                        // Clear all drawn objects after successful save
                                        self.objects.removeAll()
                                        self.selectedObjectID = nil
                                        self.activeHandle = .none
                                        self.focusedTextID = nil
                                        self.cropRect = nil
                                        self.cropDraftRect = nil
                                        self.cropHandle = .none

                                        self.selectedSnipURL = dest
                                        self.refreshGalleryAfterSaving(to: dest)
                                        self.reloadCurrentImage()
                                    }
                                }
                            }
                        } else {
                            // Fallback if no directory available - must be on main thread
                            self.saveAsCurrent()

                            // Clear objects after saveAsCurrent completes successfully
                            self.objects.removeAll()
                            self.selectedObjectID = nil
                            self.activeHandle = .none
                            self.focusedTextID = nil
                            self.cropRect = nil
                            self.cropDraftRect = nil
                            self.cropHandle = .none
                        }
                    }
                }
            }
        }
    }
    /// Flattens the current canvas into the image, refreshes state, then copies the latest to the clipboard.
    func flattenRefreshAndCopy() {
        // 1) Flatten into currentImage (and save) using existing logic
        //flattenAndSaveInPlace()
        // 2) On the next run loop, copy the refreshed image so we don't grab stale state
        DispatchQueue.main.async {
            if let current = self.currentImage {
                self.copyToPasteboard(current)
            }
        }
    }
    
    func pushUndoSnipshot() {
        undoStack.append(Snipshot(imageURL: selectedSnipURL, objects: objects))
        // Limit for 24/7 operation
        while undoStack.count > 3 { undoStack.removeFirst() }
        redoStack.removeAll()
        
        updateMenuState()
        
    }
    
    // MARK: - Save / Save As
    
    // Reset the custom save folder back to the default Pictures/Screen Snip directory.
    func resetSaveDirectoryToDefault() {
        // Remove any previously stored security-scoped bookmark + path
        UserDefaults.standard.removeObject(forKey: "saveDirectoryBookmark")
        saveDirectoryPath = ""
        // Ensure the default exists and refresh the visible list
        _ = defaultSnipsDirectory()
        loadExistingSnips()
    }
    
    /// Save As… — prompts for a destination, updates gallery if under Snips folder.
    func saveAsCurrent() {
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
            panel.nameFieldStringValue = ImageSaver.replaceExtension(of: sel.lastPathComponent, with: preferredSaveFormat.rawValue)
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
    func refreshGalleryAfterSaving(to url: URL) {
        if let dir = SnipsDirectory(), url.path.hasPrefix(dir.path) {
            loadExistingSnips()
        }
        
        // Refresh thumbnails.
        thumbnailRefreshTrigger = UUID()
        
    }
    
    
    func lineGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
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
                            if activeHandle == .none {
                                // Move whole line as a unit — clamp the delta so BOTH endpoints stay within bounds (prevents warping)
                                // Clamp X
                                let proposedStartX = o.start.x + delta.width
                                let proposedEndX   = o.end.x   + delta.width
                                var dx = delta.width
                                let minX = min(proposedStartX, proposedEndX)
                                let maxX = max(proposedStartX, proposedEndX)
                                if minX < 0 { dx -= minX }
                                if maxX > author.width { dx -= (maxX - author.width) }
                                // Clamp Y
                                let proposedStartY = o.start.y + delta.height
                                let proposedEndY   = o.end.y   + delta.height
                                var dy = delta.height
                                let minY = min(proposedStartY, proposedEndY)
                                let maxY = max(proposedStartY, proposedEndY)
                                if minY < 0 { dy -= minY }
                                if maxY > author.height { dy -= (maxY - author.height) }
                                let clampedDelta = CGSize(width: dx, height: dy)
                                let moved = o.moved(by: clampedDelta)
                                objects[idx] = .line(moved)
                            } else {
                                // Resize one endpoint: allow it to hit bounds, then clamp that endpoint only
                                var updated = o.resizing(activeHandle, to: current)
                                updated.start = clampPoint(updated.start, in: author)
                                updated.end   = clampPoint(updated.end,   in: author)
                                objects[idx] = .line(updated)
                            }
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
    func normalizedAngleDelta(from a: CGFloat, to b: CGFloat) -> CGFloat {
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

    func rectGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
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
                                // Clamp delta before moving to prevent going off-canvas (works for both rotated and non-rotated)
                                let moveDelta = o.rotation != 0
                                    ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: delta, in: author)
                                    : clampedDeltaForRect(o.rect, delta: delta, in: author)
                                updated = o.moved(by: moveDelta)
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
                                // For resizing, use unclamped point for rotated objects (clamping before resize breaks the math)
                                let resizePoint = o.rotation != 0 ? current : clampPoint(current, in: author)
                                let resized = o.resizing(activeHandle, to: resizePoint)

                                // For rotated objects, check if resize would go off-canvas
                                if o.rotation != 0 {
                                    // Only apply resize if it stays within bounds
                                    if rotatedRectFitsInBounds(resized.rect, rotation: resized.rotation, in: author) {
                                        updated = resized
                                    }
                                    // If it doesn't fit, keep the old rect (updated = o, which was set earlier)
                                } else {
                                    // For non-rotated, apply normal clamping
                                    updated = resized
                                    updated.rect = clampRect(updated.rect, in: author)
                                }
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

    func blurGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
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
                    // If starting on an existing blur rect, select it and capture which handle (if any)
                    if let idx = objects.lastIndex(where: { obj in
                        switch obj {
                        case .blur(let o): return o.handleHitTest(start) != .none || o.hitTest(start)
                        default: return false
                        }
                    }) {
                        selectedObjectID = objects[idx].id
                        if case .blur(let o) = objects[idx] { activeHandle = o.handleHitTest(start) }
                    } else {
                        selectedObjectID = nil
                        activeHandle = .none
                    }
                } else if
                    let sel = selectedObjectID,
                    let s = dragStartPoint,
                    let idx = objects.firstIndex(where: { $0.id == sel })
                {
                    // We are interacting with an existing blur rectangle: move or resize
                    let delta = CGSize(width: current.x - s.x, height: current.y - s.y)
                    let dragDistance = hypot(delta.width, delta.height)
                    if dragDistance > 0.5 {
                        if !pushedDragUndo { pushUndoSnipshot(); pushedDragUndo = true }
                        switch objects[idx] {
                        case .blur(let o):
                            var updated = o
                            if activeHandle == .none {
                                // Clamp delta before moving to prevent going off-canvas (works for both rotated and non-rotated)
                                let moveDelta = o.rotation != 0
                                    ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: delta, in: author)
                                    : clampedDeltaForRect(o.rect, delta: delta, in: author)
                                updated = o.moved(by: moveDelta)
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
                                objects[idx] = .blur(updated)
                                // Important: keep anchors stable; do not mutate dragStartPoint here
                                return
                            } else {
                                // For resizing, use unclamped point for rotated objects (clamping before resize breaks the math)
                                let resizePoint = o.rotation != 0 ? current : clampPoint(current, in: author)
                                let resized = o.resizing(activeHandle, to: resizePoint)

                                // For rotated objects, check if resize would go off-canvas
                                if o.rotation != 0 {
                                    // Only apply resize if it stays within bounds
                                    if rotatedRectFitsInBounds(resized.rect, rotation: resized.rotation, in: author) {
                                        updated = resized
                                    }
                                    // If it doesn't fit, keep the old rect (updated = o, which was set earlier)
                                } else {
                                    // For non-rotated, apply normal clamping
                                    updated = resized
                                    updated.rect = clampRect(updated.rect, in: author)
                                }
                            }
                            objects[idx] = .blur(updated)
                        default:
                            break
                        }
                        dragStartPoint = current
                    }
                } else {
                    // No selection: show a draft for creating a new blur rectangle (Shift = square)
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

                // Reset rotation anchors - same as pointer tool
                rectRotateStartAngle = nil
                rectRotateStartValue = nil

                defer { dragStartPoint = nil; pushedDragUndo = false; activeHandle = .none; draftRect = nil }

                // If we were moving/resizing an existing blur rect, generate snapshot and we're done
                if let _ = selectedObjectID,
                   let idx = objects.firstIndex(where: { $0.id == selectedObjectID }) {
                    if case .blur(let o) = objects[idx] {
                        // Generate pixelated snapshot after modification
                        generateBlurSnapshot(for: o)
                        return
                    }
                }

                // Create a new blur rectangle from the draft drag area if present
                if let r = draftRect {
                    let clamped = clampRect(r, in: author)
                    let newObj = BlurRectObject(rect: clamped, blurRadius: blurAmount)
                    pushUndoSnipshot()
                    objects.append(.blur(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                    // Generate pixelated snapshot for new blur object
                    generateBlurSnapshot(for: newObj)
                } else {
                    // on simple click with no drag, create a default-sized square (larger than other tools)
                    let d: CGFloat = 80
                    let rect = CGRect(x: max(0, pEnd.x - d/2), y: max(0, pEnd.y - d/2), width: d, height: d)
                    let clamped = clampRect(rect, in: author)
                    let newObj = BlurRectObject(rect: clamped, blurRadius: blurAmount)
                    pushUndoSnipshot()
                    objects.append(.blur(newObj))
                    if objectSpaceSize == nil { objectSpaceSize = author }
                    selectedObjectID = newObj.id
                    // Generate pixelated snapshot for new blur object
                    generateBlurSnapshot(for: newObj)
                }
            }
    }

    func ovalGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
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
                            let clampedCurrent = clampPoint(current, in: author)
                            let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: clampedCurrent)
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
    
    func highlightGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
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
                            let clampedCurrent = clampPoint(current, in: author)
                            let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: clampedCurrent)
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
    @State var textRotateStartAngle: CGFloat? = nil
    @State var textRotateStartValue: CGFloat? = nil

    func textGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
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
                    draftRect = nil
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
                                // Clamp delta before moving to prevent going off-canvas (works for both rotated and non-rotated)
                                let moveDelta = o.rotation != 0
                                    ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: delta, in: author)
                                    : clampedDeltaForRect(o.rect, delta: delta, in: author)
                                updated = o.moved(by: moveDelta)
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
                                // For resizing, use unclamped point for rotated objects (clamping before resize breaks the math)
                                let resizePoint = o.rotation != 0 ? p : clampPoint(p, in: author)
                                let resized = o.resizing(activeHandle, to: resizePoint)

                                // For rotated objects, check if resize would go off-canvas
                                if o.rotation != 0 {
                                    // Only apply resize if it stays within bounds
                                    if rotatedRectFitsInBounds(resized.rect, rotation: resized.rotation, in: author) {
                                        updated = resized
                                    }
                                    // If it doesn't fit, keep the old rect (updated = o, which was set earlier)
                                } else {
                                    // For non-rotated, apply normal clamping
                                    updated = resized
                                    updated.rect = clampRect(updated.rect, in: author)
                                }
                            }
                            objects[idx] = .text(updated)
                        default:
                            break
                        }
                        dragStartPoint = p
                    }
                } else if selectedObjectID == nil, let start = dragStartPoint {
                    let rect = CGRect(
                        x: min(start.x, p.x),
                        y: min(start.y, p.y),
                        width: abs(p.x - start.x),
                        height: abs(p.y - start.y)
                    )
                    draftRect = rect
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
                
                if moved && selectedObjectID != nil {
                    // We were dragging — finish and clean up
                    dragStartPoint = nil
                    pushedDragUndo = false
                    draftRect = nil
                    return
                }
                
                // CLICK (or DOUBLE-CLICK) PATH:
                dragStartPoint = nil
                pushedDragUndo = false
                defer { draftRect = nil }
                
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
                    let defaultText = "Text"
                    let minSize = TextObject.intrinsicSize(for: defaultText, fontSize: textFontSize)
                    var baseRect: CGRect
                    if let draft = draftRect, draft.width >= 2, draft.height >= 2 {
                        baseRect = draft
                    } else {
                        baseRect = CGRect(
                            x: max(0, pEnd.x - minSize.width / 2),
                            y: max(0, pEnd.y - minSize.height / 2),
                            width: minSize.width,
                            height: minSize.height
                        )
                    }
                    var rect = clampRect(baseRect, in: author)
                    if rect.width < minSize.width {
                        rect.size.width = minSize.width
                        rect = clampRect(rect, in: author)
                    }
                    if rect.height < minSize.height {
                        rect.size.height = minSize.height
                        rect = clampRect(rect, in: author)
                    }
                    let newObj = TextObject(rect: rect,
                                            text: defaultText,
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
    @State var rectRotateStartAngle: CGFloat? = nil
    @State var rectRotateStartValue: CGFloat? = nil
    @State var imageRotateStartAngle: CGFloat? = nil
    @State var imageRotateStartValue: CGFloat? = nil
    @State var blurRotateStartAngle: CGFloat? = nil
    @State var blurRotateStartValue: CGFloat? = nil

    func performUndo() {
        guard let prev = undoStack.popLast() else { return }
        let current = Snipshot(imageURL: selectedSnipURL, objects: objects)
        redoStack.append(current)
        selectedSnipURL = prev.imageURL  // Just change the URL
        objects = prev.objects
        
        updateMenuState()
        
    }
    
    func performRedo() {
        guard let next = redoStack.popLast() else { return }
        let current = Snipshot(imageURL: selectedSnipURL, objects: objects)
        undoStack.append(current)
        selectedSnipURL = next.imageURL  // Just change the URL
        objects = next.objects
        
        updateMenuState()
        
    }
    

}
