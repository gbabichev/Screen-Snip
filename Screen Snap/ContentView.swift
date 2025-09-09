

import SwiftUI
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import UniformTypeIdentifiers

private enum Tool { case pointer, line, rect }

struct ContentView: View {
    @State private var lastCapture: NSImage? = nil
    @State private var showCopiedHUD = false
    @State private var selectedTool: Tool = .pointer
    // Removed lines buffer; we now auto-commit each line on mouse-up.
    @State private var draft: Line? = nil
    @State private var draftRect: CGRect? = nil
    @State private var strokeWidth: CGFloat = 3
    @State private var strokeColor: NSColor = .black
    @State private var lineHasArrow: Bool = false
    // Snaps persisted on disk (newest first). Each element is a file URL to a PNG.
    @State private var snapURLs: [URL] = []
    @State private var selectedSnapURL: URL? = nil

    // Undo/Redo stacks of full images (save-in-place, memory-bounded by user behavior)
    @State private var undoStack: [NSImage] = []
    @State private var redoStack: [NSImage] = []
    @State private var keyMonitor: Any? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Main canvas
            VStack(spacing: 12) {

                Group {
                    if let img = lastCapture {
                        ZStack {
                            GeometryReader { geo in
                                let fitted = fittedImageSize(original: img.size, in: geo.size)
                                let origin = CGPoint(
                                    x: (geo.size.width - fitted.width)/2,
                                    y: (geo.size.height - fitted.height)/2
                                )

                                // Base image
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: fitted.width, height: fitted.height)
                                    .position(x: origin.x + fitted.width/2, y: origin.y + fitted.height/2)

                                // Lines overlay (coordinates in the displayed image space)
                                ZStack {
                                    if let d = draft {
                                        Path { p in p.move(to: d.start); p.addLine(to: d.end) }
                                            .stroke(Color(nsColor: strokeColor), style: StrokeStyle(lineWidth: d.width, dash: [6,4]))
                                    }
                                    if let r = draftRect {
                                        Rectangle()
                                            .path(in: r)
                                            .stroke(Color(nsColor: strokeColor), style: StrokeStyle(lineWidth: strokeWidth, dash: [6,4]))
                                    }
                                }
                                .frame(width: fitted.width, height: fitted.height)
                                .position(x: origin.x + fitted.width/2, y: origin.y + fitted.height/2)
                                .contentShape(Rectangle())
                                .allowsHitTesting(selectedTool != .pointer)
                                .gesture(selectedTool == .line ? lineGesture(insetOrigin: origin, fitted: fitted) : nil)
                                .simultaneousGesture(selectedTool == .rect ? rectGesture(insetOrigin: origin, fitted: fitted) : nil)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "camera")
                                .imageScale(.large)
                                .foregroundStyle(.tint)
                            Text("Press ⇧⌘2 or click ‘Capture Region’ to begin.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
                Spacer()
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
                    Text("Snaps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                                        height: 90
                                    )
                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 140)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let img = NSImage(contentsOf: url) {
                                        lastCapture = img
                                        selectedSnapURL = url
                                        undoStack.removeAll(); redoStack.removeAll()
                                    }
                                }
                                .contextMenu {
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .background(.quaternary.opacity(0.05))
                }
                .padding(.top, 4)
                .background(.thinMaterial) // keep it distinct and readable
            }
        }
        .onAppear {
            loadExistingSnaps()
            // Listen for Cmd+Z / Shift+Cmd+Z globally while this view is active
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
                    if chars == "z" {
                        if event.modifierFlags.contains(.shift) {
                            performRedo()
                        } else {
                            performUndo()
                        }
                        return nil // consume
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    //selectFolders()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: [.command])
                
                Button {
                    //showSettingsPopover = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        
            // Items visible only when we have a capture
            if let img = lastCapture {
                
                ToolbarItemGroup(placement: .principal) {
                    Button(action: { copyToPasteboard(img) }) {
                        Label("Copy Last", systemImage: "doc.on.doc")
                    }
                    
                    Button(action: performUndo) {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(undoStack.isEmpty || lastCapture == nil)
                    
                    Button(action: performRedo) {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .keyboardShortcut("Z", modifiers: [.command, .shift])
                    .disabled(redoStack.isEmpty || lastCapture == nil)
                    
//                    Menu {
//                        Button("Save", action: saveCurrentOverwrite)
//                        Button("Save As…", action: saveAsCurrent)
//                    } label: {
//                        Label("Save", systemImage: "square.and.arrow.down")
//                    } primaryAction: {
//                        saveCurrentOverwrite()
//                    }
//                    
                    Button(action: { selectedTool = .pointer }) {
                        Label("Pointer", systemImage: "cursorarrow")
                    }
                    .tint(selectedTool == .pointer ? Color.accentColor : Color.gray)
                    
                    Menu {
                        Toggle("Arrowhead on end", isOn: $lineHasArrow)
                        Divider()

                        Menu("Line Width") {
                            ForEach([1,2,3,4,6,8,12,16], id: \.self) { w in
                                Button(action: { strokeWidth = CGFloat(w) }) {
                                    if Int(strokeWidth) == w { Image(systemName: "checkmark") }
                                    Text("\(w) pt")
                                }
                            }
                        }
                        Menu("Color") {
                            PenColorButton(current: $strokeColor, color: .black, name: "Black")
                            PenColorButton(current: $strokeColor, color: .red, name: "Red")
                            PenColorButton(current: $strokeColor, color: .blue, name: "Blue")
                            PenColorButton(current: $strokeColor, color: .systemGreen, name: "Green")
                            PenColorButton(current: $strokeColor, color: .systemYellow, name: "Yellow")
                            PenColorButton(current: $strokeColor, color: .white, name: "White")
                        }
                    } label: {
                        Label("Pen", systemImage: "pencil.line")
                            .foregroundStyle(selectedTool == .line ? Color.accentColor : Color.primary)
                    } primaryAction: {
                        selectedTool = .line
                    }
                    
                    Menu {
                        // Reuse stroke controls for shapes
                        Menu("Line Width") {
                            ForEach([1,2,3,4,6,8,12,16], id: \.self) { w in
                                Button(action: { strokeWidth = CGFloat(w) }) {
                                    if Int(strokeWidth) == w { Image(systemName: "checkmark") }
                                    Text("\(w) pt")
                                }
                            }
                        }
                        Menu("Color") {
                            PenColorButton(current: $strokeColor, color: .black, name: "Black")
                            PenColorButton(current: $strokeColor, color: .red, name: "Red")
                            PenColorButton(current: $strokeColor, color: .blue, name: "Blue")
                            PenColorButton(current: $strokeColor, color: .systemGreen, name: "Green")
                            PenColorButton(current: $strokeColor, color: .systemYellow, name: "Yellow")
                            PenColorButton(current: $strokeColor, color: .white, name: "White")
                        }
                        Divider()
                        Text("Hold ⇧ for a perfect square")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Shapes", systemImage: "square.dashed")
                            .foregroundStyle(selectedTool == .rect ? Color.accentColor : Color.primary)
                    } primaryAction: {
                        selectedTool = .rect
                    }
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
    }

    private func startSelection() {
        SelectionWindowManager.shared.present(onComplete: { rect in
            Task {
                if let img = await captureAsync(rect: rect) {
                    undoStack.removeAll(); redoStack.removeAll()
                    lastCapture = img
                    if let savedURL = saveSnapToDisk(img) {
                        insertSnapURL(savedURL)
                        selectedSnapURL = savedURL
                    }
                    copyToPasteboard(img)
                    withAnimation { showCopiedHUD = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation { showCopiedHUD = false }
                    }
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

        // 1) Determine which NSScreen the selection mostly lies on.
        guard let bestScreen = bestScreenForSelection(selectedGlobalRect) else { return nil }
        let screenFramePts = bestScreen.frame
        // let scale = bestScreen.backingScaleFactor // REMOVED

        // 2) Map selection to that screen and intersect.
        let intersectPts = selectedGlobalRect.intersection(screenFramePts)
        if intersectPts.isNull || intersectPts.isEmpty { return nil }

        // 3) Find matching SCDisplay by CGDisplayID.
        guard let cgIDNum = bestScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let cgID = CGDirectDisplayID(truncating: cgIDNum)

        do {
            let content = try await SCShareableContent.current
            guard let scDisplay = content.displays.first(where: { $0.displayID == cgID }) else { return nil }

            // Compute precise pixels-per-point per axis from SCDisplay + NSScreen
            let pxPerPtX = CGFloat(scDisplay.width) / screenFramePts.width
            let pxPerPtY = CGFloat(scDisplay.height) / screenFramePts.height

            // 4) Build a filter for that display and capture one frame.
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            guard let fullCG = await ScreenCapturer.shared.captureImage(using: filter, display: scDisplay) else { return nil }

            // 5) Convert the intersected rect (points) to pixel crop in the captured image space.
            let cropPx = cropRectPixels(intersectPts,
                                        withinScreenFramePts: screenFramePts,
                                        imageSizePx: CGSize(width: fullCG.width, height: fullCG.height),
                                        scaleX: pxPerPtX,
                                        scaleY: pxPerPtY)

            let clamped = CGRect(x: max(0, cropPx.origin.x),
                                 y: max(0, cropPx.origin.y),
                                 width: min(cropPx.width, CGFloat(fullCG.width) - max(0, cropPx.origin.x)),
                                 height: min(cropPx.height, CGFloat(fullCG.height) - max(0, cropPx.origin.y)))
            guard clamped.width > 1, clamped.height > 1 else { return nil }

            guard let cropped = fullCG.cropping(to: clamped) else { return nil }
            return NSImage(cgImage: cropped, size: .zero)
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
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    // MARK: - Save / Save As

    private func defaultSnapFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return "snap_\(formatter.string(from: Date())).png"
    }

    /// Writes the image as PNG to a URL. Returns true on success.
    @discardableResult
    private func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Save As… — prompts for a destination, updates gallery if under snaps folder.
    private func saveAsCurrent() {
        guard let img = lastCapture else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let sel = selectedSnapURL {
            panel.directoryURL = sel.deletingLastPathComponent()
            panel.nameFieldStringValue = sel.lastPathComponent
        } else if let dir = snapsDirectory() {
            panel.directoryURL = dir
            panel.nameFieldStringValue = defaultSnapFilename()
        } else {
            panel.nameFieldStringValue = defaultSnapFilename()
        }
        if panel.runModal() == .OK, let url = panel.url {
            if writePNG(img, to: url) {
                selectedSnapURL = url
                refreshGalleryAfterSaving(to: url)
            }
        }
    }

    /// Save — overwrites the currently selected snap if available, else falls back to Save As….
    private func saveCurrentOverwrite() {
        guard let img = lastCapture else { return }
        if let url = selectedSnapURL {
            if writePNG(img, to: url) {
                refreshGalleryAfterSaving(to: url)
            }
        } else {
            saveAsCurrent()
        }
    }

    /// If saved file is within our snaps directory, update the gallery list.
    private func refreshGalleryAfterSaving(to url: URL) {
        if let dir = snapsDirectory(), url.path.hasPrefix(dir.path) {
            insertSnapURL(url)
        }
    }

    private func lineGesture(insetOrigin: CGPoint, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let pRaw = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let sRaw = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                if draft == nil { draft = Line(start: sRaw, end: pRaw, width: strokeWidth) }
                let shift = NSEvent.modifierFlags.contains(.shift)
                if let start = draft?.start {
                    draft?.end = shift ? snappedPoint(start: start, raw: pRaw) : pRaw
                }
                draft?.width = strokeWidth
            }
            .onEnded { value in
                let pRaw = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let shift = NSEvent.modifierFlags.contains(.shift)
                guard let base = lastCapture, let start = draft?.start else { draft = nil; return }

                // End point in UI space, with optional snapping
                let endUI = shift ? snappedPoint(start: start, raw: pRaw) : pRaw

                // Map both start/end to image pixel space with Y-flip
                let startImg = uiToImagePoint(start, fitted: fitted, image: base.size)
                let endImg   = uiToImagePoint(endUI, fitted: fitted, image: base.size)

                // Line width scaled to image pixels
                let scaleX = base.size.width / max(1, fitted.width)
                let scaleY = base.size.height / max(1, fitted.height)
                let widthImg = strokeWidth * ((scaleX + scaleY) / 2)

                let committedLine = Line(start: startImg, end: endImg, width: widthImg)
                if let composed = composeAnnotated(base: base, lines: [committedLine], arrowHeadAtEnd: lineHasArrow) {
                    commitChange(composed)
                }
                draft = nil
            }
    }

    // finishInlineAnnotation and cancelInlineAnnotation removed; not needed with auto-commit per line.

    private func composeAnnotated(base: NSImage, lines: [Line] = [], rects: [Box] = [], arrowHeadAtEnd: Bool = false) -> NSImage? {
        let imgSize = base.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(imgSize.width),
                                   pixelsHigh: Int(imgSize.height),
                                   bitsPerSample: 8,
                                   samplesPerPixel: 4,
                                   hasAlpha: true,
                                   isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0,
                                   bitsPerPixel: 0)
        guard let rep else { return nil }
        let composed = NSImage(size: imgSize)
        composed.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        base.draw(in: CGRect(origin: .zero, size: imgSize))
        strokeColor.setStroke()
        strokeColor.setFill()

        for line in lines {
            // Draw the shaft
            let path = NSBezierPath()
            path.lineWidth = line.width
            path.lineCapStyle = .round
            path.move(to: line.start)
            path.line(to: line.end)
            path.stroke()

            // Optionally draw an arrowhead at the end
            if arrowHeadAtEnd {
                let dx = line.end.x - line.start.x
                let dy = line.end.y - line.start.y
                let len = max(1, hypot(dx, dy))
                // Arrowhead dimensions scale with stroke width, capped by line length
                let headLength = min(len * 0.8, max(10, 6 * line.width))
                let headWidth  = max(8, 5 * line.width)
                let ux = dx / len
                let uy = dy / len
                // Base of the triangle
                let bx = line.end.x - ux * headLength
                let by = line.end.y - uy * headLength
                // Perpendicular vector
                let px = -uy
                let py = ux
                let p1 = CGPoint(x: bx + px * (headWidth / 2), y: by + py * (headWidth / 2))
                let p2 = CGPoint(x: bx - px * (headWidth / 2), y: by - py * (headWidth / 2))

                let tri = NSBezierPath()
                tri.move(to: line.end)
                tri.line(to: p1)
                tri.line(to: p2)
                tri.close()
                tri.fill()
            }
        }
        for box in rects {
            let rectPath = NSBezierPath(rect: box.rect)
            rectPath.lineWidth = box.width
            rectPath.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return composed
    }

    private func rectGesture(insetOrigin: CGPoint, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let current = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let shift = NSEvent.modifierFlags.contains(.shift)

                func rectFrom(_ a: CGPoint, _ b: CGPoint, square: Bool) -> CGRect {
                    var x0 = min(a.x, b.x)
                    var y0 = min(a.y, b.y)
                    var w = abs(a.x - b.x)
                    var h = abs(a.y - b.y)
                    if square {
                        let side = max(w, h)
                        // preserve drag direction relative to start point
                        x0 = (b.x >= a.x) ? a.x : (a.x - side)
                        y0 = (b.y >= a.y) ? a.y : (a.y - side)
                        w = side; h = side
                    }
                    return CGRect(x: x0, y: y0, width: w, height: h)
                }

                draftRect = rectFrom(start, current, square: shift)
            }
            .onEnded { value in
                defer { draftRect = nil }
                guard let base = lastCapture, let uiRect = draftRect else { return }

                // Map UI-space rect (origin top-left, y-down) to image pixel space (origin bottom-left, y-up)
                let imgRect = uiRectToImageRect(uiRect, fitted: fitted, image: base.size)

                // Scale line width to image pixels
                let scaleX = base.size.width / max(1, fitted.width)
                let scaleY = base.size.height / max(1, fitted.height)
                let widthImg = strokeWidth * ((scaleX + scaleY) / 2)

                let box = Box(rect: imgRect, width: widthImg)
                if let composed = composeAnnotated(base: base, rects: [box]) {
                    commitChange(composed)
                }
            }
    }

    // MARK: - Commit & Undo/Redo
    private func commitChange(_ newImage: NSImage) {
        if let current = lastCapture {
            undoStack.append(current)
        }
        redoStack.removeAll()
        lastCapture = newImage
        if let url = selectedSnapURL {
            if writePNG(newImage, to: url) {
                refreshGalleryAfterSaving(to: url)
            }
        }
        copyToPasteboard(newImage)
        withAnimation { showCopiedHUD = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { showCopiedHUD = false }
        }
    }

    private func performUndo() {
        guard let previous = undoStack.popLast(), let current = lastCapture else { return }
        redoStack.append(current)
        lastCapture = previous
        if let url = selectedSnapURL {
            if writePNG(previous, to: url) {
                refreshGalleryAfterSaving(to: url)
            }
        }
        copyToPasteboard(previous)
        withAnimation { showCopiedHUD = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation { showCopiedHUD = false }
        }
    }

    private func performRedo() {
        guard let next = redoStack.popLast(), let current = lastCapture else { return }
        undoStack.append(current)
        lastCapture = next
        if let url = selectedSnapURL {
            if writePNG(next, to: url) {
                refreshGalleryAfterSaving(to: url)
            }
        }
        copyToPasteboard(next)
        withAnimation { showCopiedHUD = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation { showCopiedHUD = false }
        }
    }

    private func uiRectToImageRect(_ r: CGRect, fitted: CGSize, image: CGSize) -> CGRect {
        let scaleX = image.width / max(1, fitted.width)
        let scaleY = image.height / max(1, fitted.height)
        let x = r.origin.x * scaleX
        let y = (fitted.height - (r.origin.y + r.height)) * scaleY // convert top-left origin to bottom-left
        return CGRect(x: x, y: y, width: r.width * scaleX, height: r.height * scaleY)
    }

    private func fittedImageSize(original: CGSize, in container: CGSize) -> CGSize {
        let scale = min(container.width / max(1, original.width), container.height / max(1, original.height))
        return CGSize(width: original.width * scale, height: original.height * scale)
    }

    private func uiToImagePoint(_ p: CGPoint, fitted: CGSize, image: CGSize) -> CGPoint {
        let scaleX = image.width / max(1, fitted.width)
        let scaleY = image.height / max(1, fitted.height)
        // UI space: (0,0) is top-left of fitted image (Y down); Image space: (0,0) is bottom-left (Y up)
        return CGPoint(x: p.x * scaleX, y: (fitted.height - p.y) * scaleY)
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

    // MARK: - Snaps Persistence

    /// Directory where we store PNG snaps.
    private func snapsDirectory() -> URL? {
        let fm = FileManager.default
        if let pics = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
            let dir = pics.appendingPathComponent("screenshotG Snaps", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
            }
            return dir
        }
        return nil
    }

    /// Saves an NSImage as PNG to disk; returns the file URL if successful.
    private func saveSnapToDisk(_ image: NSImage) -> URL? {
        guard let dir = snapsDirectory() else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let name = "snap_\(formatter.string(from: Date())).png"
        let url = dir.appendingPathComponent(name)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Loads existing snaps on disk (PNG files), newest first.
    private func loadExistingSnaps() {
        guard let dir = snapsDirectory() else { return }
        let fm = FileManager.default
        do {
            let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "png" }
            let dated: [(URL, Date)] = urls.compactMap {
                let vals = try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                return ($0, vals?.contentModificationDate ?? .distantPast)
            }
            let sorted = dated.sorted { $0.1 > $1.1 }.map { $0.0 }
            snapURLs = sorted
            // If nothing currently selected, keep nil; else preserve selection if still present.
            if let sel = selectedSnapURL, !sorted.contains(sel) {
                selectedSnapURL = nil
            }
        } catch {
            snapURLs = []
        }
    }

    /// Inserts a newly saved URL at the start of the list (leftmost), de-duplicating if necessary.
    private func insertSnapURL(_ url: URL) {
        if let idx = snapURLs.firstIndex(of: url) {
            snapURLs.remove(at: idx)
        }
        snapURLs.insert(url, at: 0)
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
            if let first = selectedSnapURL, let img = NSImage(contentsOf: first) {
                lastCapture = img
            } else {
                lastCapture = nil
            }
        }
    }

    // MARK: - Thumbnail View

    private struct ThumbnailView: View {
        let url: URL
        let selected: Bool
        let onDelete: () -> Void
        let width: CGFloat
        let height: CGFloat
        @State private var hovering = false
        @State private var hoverDebounce = 0

        var body: some View {
            ZStack {
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.low)
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.secondary.opacity(0.1))
                        Image(systemName: "photo")
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isIn in
                if isIn {
                    hovering = true
                    hoverDebounce &+= 1
                } else {
                    let token = hoverDebounce
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        if token == hoverDebounce {
                            hovering = false
                        }
                    }
                }
            }
            // Selection border calculated at final size
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: selected ? 2 : 1)
            )
            // Hover controls + selected checkmark pinned to top trailing of final bounds
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                    .opacity(hovering ? 1 : 0.001)          // keep in layout, nearly invisible when not hovering
                    .allowsHitTesting(hovering)             // only clickable when hovering
                    .onHover { isIn in
                        if isIn {
                            // Keep hover alive and cancel any pending exit
                            hovering = true
                            hoverDebounce &+= 1
                        } else {
                            // Mirror the container's debounced exit to avoid flicker when moving off the icon
                            let token = hoverDebounce
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                if token == hoverDebounce {
                                    hovering = false
                                }
                            }
                        }
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                .padding(4)
            }
        }
    }
}

// MARK: - Selection Overlay

/// A full-desktop translucent overlay that lets the user click–drag to choose a rectangle.
private struct SelectionOverlay: View {
    let windowOrigin: CGPoint
    let onComplete: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            // Cover the entire screen space with a dim layer
            Color.black.opacity(0.25)
                .overlay(alignment: .topLeading) {
                    if let rect = selectionRect(in: geo) {
                        // Cut-out effect
                        SelectionShape(rect: rect)
                            .fill(style: FillStyle(eoFill: true))
                            .compositingGroup()
                            .luminanceToAlpha()
                        // Visible selection border
                        Rectangle()
                            .path(in: rect)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(in: geo))
                .onTapGesture(count: 2) { onCancel() }
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

    private func selectionRect(in geo: GeometryProxy) -> CGRect? {
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
    func path(in _: CGRect) -> Path {
        var p = Path(CGRect(x: 0, y: 0, width: NSScreen.screens.map { $0.frame.maxX }.max() ?? 0,
                              height: NSScreen.screens.map { $0.frame.maxY }.max() ?? 0))
        p.addRect(rect)
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

// MARK: - Inline Annotation Types
private struct Line: Identifiable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var width: CGFloat
}

private struct Box: Identifiable {
    let id = UUID()
    var rect: CGRect
    var width: CGFloat
}

final class ScreenCapturer: NSObject, SCStreamOutput {
    static let shared = ScreenCapturer()

    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage?, Never>?

    /// Captures a single CGImage of the main display using ScreenCaptureKit.
    func captureMainDisplayImage() async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            self.stream = stream

            try await stream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: DispatchQueue.main)
            try await stream.startCapture()

            return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                self.continuation = cont
            }
        } catch {
            return nil
        }
    }

    func captureImage(using filter: SCContentFilter, display: SCDisplay) async -> CGImage? {
        do {
            let cfg = SCStreamConfiguration()
            // Use the display's native pixel size to avoid point/pixel mismatches on Retina and multi-display setups.
            cfg.width = display.width
            cfg.height = display.height
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)

            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            self.stream = stream
            try await stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()

            return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                self.continuation = cont
            }
        } catch {
            return nil
        }
    }

    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)

        if let cgImage {
            continuation?.resume(returning: cgImage)
            continuation = nil

            Task { [weak self] in
                do {
                    try await self?.stream?.stopCapture()
                    if let self { try await self.stream?.removeStreamOutput(self, type: .screen) }
                } catch { }
                self?.stream = nil
            }
        }
    }
}



final class SelectionWindowManager {
    static let shared = SelectionWindowManager()
    private var panel: NSPanel?
    private var keyMonitor: Any?

    func present(onComplete: @escaping (CGRect) -> Void) {
        guard panel == nil else { return }
        guard let screen = NSScreen.main else { return }

        let frame = screen.frame
        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false,
                            screen: screen)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        // SwiftUI overlay content
        let root = SelectionOverlay(windowOrigin: frame.origin,
                                    onComplete: { rect in
                                        onComplete(rect)
                                        self.dismiss()
                                    },
                                    onCancel: { self.dismiss() })
            .ignoresSafeArea()

        panel.contentView = NSHostingView(rootView: root)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel

        // Listen for ESC to cancel selection
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 53 is the ESC key on macOS
            if event.keyCode == 53 {
                self.dismiss()
                return nil // consume event
            }
            return event
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
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
                if current == color { Image(systemName: "checkmark") }
            }
        }
    }
}


