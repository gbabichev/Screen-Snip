

import SwiftUI
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import UniformTypeIdentifiers

// File-scope helpers for robust double-click detection
private var _lastClickTime: TimeInterval = 0
private var _lastClickPoint: CGPoint = .zero

private enum Tool { case pointer, line, rect, text, crop, badge, highlighter }

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
    
    @State private var missingSnapURLs: Set<URL> = []
    
    
    @State private var showSettingsPopover = false
    @AppStorage("preferredSaveFormat") private var preferredSaveFormatRaw: String = SaveFormat.png.rawValue
    private var preferredSaveFormat: SaveFormat {
        get { SaveFormat(rawValue: preferredSaveFormatRaw) ?? .png }
        set { preferredSaveFormatRaw = newValue.rawValue }
    }
    
    @AppStorage("saveQuality") private var saveQuality: Double = 0.9
    @AppStorage("saveDirectoryPath") private var saveDirectoryPath: String = ""
    private enum ImporterKind { case image, folder }
    @State private var activeImporter: ImporterKind? = nil
    
    @FocusState private var isTextEditorFocused: Bool
    
    @State private var focusedTextID: UUID? = nil
    @State private var lastCapture: NSImage? = nil
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
    @State private var strokeColor: NSColor = .black
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
        let image: NSImage?
        let objects: [Drawable]
    }
    @State private var undoStack: [Snapshot] = []
    @State private var redoStack: [Snapshot] = []
    @State private var pushedDragUndo = false
    @State private var keyMonitor: Any? = nil
    
    @State private var textFontSize: CGFloat = 18
    @State private var textColor: NSColor = .white
    @State private var textBGEnabled: Bool = true
    @State private var textBGColor: NSColor = .black.withAlphaComponent(0.6)
    @State private var badgeColor: NSColor = .systemRed
    @State private var badgeCount: Int = 0
    @State private var highlighterColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.35)
    
    @State private var lastFittedSize: CGSize? = nil
    @State private var objectSpaceSize: CGSize? = nil  // tracks the UI coordinate space size the objects are authored in
    @State private var resizeSeq: Int = 0
    
    @State private var showTextEditor: Bool = false
    @State private var editingText: String = ""
    @State private var lastDraftTick: CFTimeInterval = 0
    
    // Throttle rapid draft updates to ~90 Hz (for drag gestures)
    private func allowDraftTick(interval: Double = 1.0/90.0) -> Bool {
        let now = CACurrentMediaTime()
        if now - lastDraftTick < interval { return false }
        lastDraftTick = now
        return true
    }
    
    
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
                                let author = objectSpaceSize ?? fitted
                                let sx = fitted.width / max(1, author.width)
                                let sy = fitted.height / max(1, author.height)
                                
                                // Base image
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: fitted.width, height: fitted.height)
                                    .position(x: origin.x + fitted.width/2, y: origin.y + fitted.height/2)
                                
                                // Object overlay drawn in author space and scaled live to fitted
                                ZStack {
                                    // Persisted objects
                                    ForEach(objects) { obj in
                                        switch obj {
                                        case .line(let o):
                                            o.drawPath(in: author)
                                                .stroke(Color(nsColor: strokeColor), style: StrokeStyle(lineWidth: o.width, lineCap: .round))
                                        case .rect(let o):
                                            o.drawPath(in: author)
                                                .stroke(Color(nsColor: strokeColor), style: StrokeStyle(lineWidth: o.width))
                                        case .text(let o):
                                            // Only render static text if it's not currently being edited
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
                                    // Draft feedback while creating (draft is stored in author space)
                                    if let d = draft {
                                        Path { p in p.move(to: d.start); p.addLine(to: d.end) }
                                            .stroke(Color(nsColor: strokeColor).opacity(0.8), style: StrokeStyle(lineWidth: d.width, dash: [6,4]))
                                    }
                                    if let r = draftRect {
                                        Rectangle().path(in: r)
                                            .stroke(Color(nsColor: strokeColor).opacity(0.8), style: StrokeStyle(lineWidth: strokeWidth, dash: [6,4]))
                                    }
                                    if let crp = cropRect {
                                        Rectangle().path(in: crp)
                                            .stroke(Color.orange.opacity(0.95), style: StrokeStyle(lineWidth: max(1, strokeWidth), dash: [8,4]))
                                            .overlay(
                                                Rectangle().path(in: crp).fill(Color.orange.opacity(0.10))
                                            )
                                        
                                        // Corner handles to indicate the crop can be dragged/resized
                                        let pts = [
                                            CGPoint(x: crp.minX, y: crp.minY),
                                            CGPoint(x: crp.maxX, y: crp.minY),
                                            CGPoint(x: crp.minX, y: crp.maxY),
                                            CGPoint(x: crp.maxX, y: crp.maxY)
                                        ]
                                        ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                                            Circle()
                                                .stroke(Color.orange, lineWidth: 1)
                                                .background(Circle().fill(Color.white))
                                                .frame(width: 12, height: 12)
                                                .position(pt)
                                        }
                                    }
                                    if let cr = cropDraftRect {
                                        Rectangle().path(in: cr)
                                            .stroke(Color.orange.opacity(0.9), style: StrokeStyle(lineWidth: max(1, strokeWidth), dash: [8,4]))
                                            .overlay(
                                                Rectangle().path(in: cr).fill(Color.orange.opacity(0.12))
                                            )
                                    }
                                }
                                .frame(width: author.width, height: author.height)
                                .scaleEffect(x: sx, y: sy, anchor: .topLeading)
                                .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
                                .position(x: origin.x + fitted.width/2, y: origin.y + fitted.height/2)
                                .transaction { $0.disablesAnimations = true }
                                .compositingGroup()
                                .drawingGroup()
                                .overlay(alignment: .topLeading) {
                                    if let sel = selectedObjectID, let idx = objects.firstIndex(where: { $0.id == sel }) {
                                        switch objects[idx] {
                                        case .line(let o):  selectionForLine(o)
                                        case .rect(let o):  selectionForRect(o)
                                        case .text(let o):  selectionForText(o)   // interactive TextEditor now outside drawingGroup
                                        case .badge(let o): selectionForBadge(o)
                                        case .highlight(let o): selectionForHighlight(o)
                                        case .image(let o): selectionForImage(o)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                                .allowsHitTesting(true)
                                .simultaneousGesture(selectedTool == .pointer ? pointerGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                .simultaneousGesture(selectedTool == .line ? lineGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                .simultaneousGesture(selectedTool == .rect ? rectGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                .simultaneousGesture(selectedTool == .text ? textGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                .simultaneousGesture(selectedTool == .crop ? cropGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                .simultaneousGesture(selectedTool == .badge ? badgeGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                .simultaneousGesture(selectedTool == .highlighter ? highlightGesture(insetOrigin: origin, fitted: fitted, author: author) : nil)
                                .onAppear {
                                    lastFittedSize = fitted
                                    if objectSpaceSize == nil { objectSpaceSize = fitted }
                                }
                                .onChange(of: geo.size) { _,_ in
                                    // Track latest fitted size for rasterization; do not mutate objects during live resize
                                    lastFittedSize = fitted
                                    if objectSpaceSize == nil { objectSpaceSize = fitted }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            // Show different content based on whether we have snaps but they're missing
                            if !missingSnapURLs.isEmpty {
                                // We had snaps but some are missing - show error state
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .imageScale(.large)
                                        .foregroundStyle(.orange)
                                    Text("Some images were deleted from disk")
                                        .fontWeight(.medium)
                                    Text("Press ⇧⌘2 to capture a new screenshot")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if !snapURLs.isEmpty {
                                // We have snaps, but no image selected - show the camera icon
                                Image(systemName: "camera")
                                    .imageScale(.large)
                                    .foregroundStyle(.tint)
                                Text("Press ⇧⌘2 or click 'Capture Region' to begin.")
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            } else {
                                // No snaps at all - show normal empty state
                                Image(systemName: "camera")
                                    .imageScale(.large)
                                    .foregroundStyle(.tint)
                                Text("Press ⇧⌘2 or click 'Capture Region' to begin.")
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                            }
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
                    
                    HStack(spacing: 6) {
                        Text("Snaps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Button(action: {
                            loadExistingSnaps()
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
                                            lastCapture = nil
                                        }
                                        return
                                    }
                                    
                                    // File exists - proceed normally
                                    if let img = NSImage(contentsOf: url) {
                                        lastCapture = img
                                        selectedSnapURL = url
                                        undoStack.removeAll(); redoStack.removeAll()
                                        objects.removeAll()
                                        objectSpaceSize = nil
                                        selectedObjectID = nil
                                        activeHandle = .none
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
                
                // Enter/Return to commit  when Crop tool is active
                if selectedTool == .crop, let rect = cropRect, !event.modifierFlags.contains(.command) {
                    if event.keyCode == 36 || event.keyCode == 76 { // Return or Keypad Enter
                        // Perform destructive crop with current overlay
                        if let base = lastCapture {
                            if objectSpaceSize == nil { objectSpaceSize = lastFittedSize ?? base.size }
                            pushUndoSnapshot()
                            let flattened = rasterize(base: base, objects: objects) ?? base
                            let imgRectBL = uiRectToImageRect(rect, fitted: objectSpaceSize ?? base.size, image: flattened.size)
                            if let cropped = cropImage(flattened, toBottomLeftRect: imgRectBL) {
                                lastCapture = cropped
                                objects.removeAll()
                                objectSpaceSize = nil
                                selectedObjectID = nil
                                activeHandle = .none
                                cropRect = nil
                                cropDraftRect = nil
                                cropHandle = .none
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
            // Wire ContentView's selection function into the always-on coordinator
            SelectionCoordinator.shared.register { completion in
                print("[DEBUG] ContentView: register handler -> startSelection()")
                startSelection()
                // We don't need to return a URL here because startSelection() handles opening the editor.
                completion(nil)
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LoadSpecificSnap"))) { note in
            guard let url = note.object as? URL else { return }
            if let img = NSImage(contentsOf: url) {
                lastCapture = img
                selectedSnapURL = url
                undoStack.removeAll()
                redoStack.removeAll()
                objects.removeAll()
                objectSpaceSize = nil
                selectedObjectID = nil
                activeHandle = .none
            }
        }
//        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("com.georgebabichev.screensnap.beginSnapFromIntent"))) { _ in
//            print("test")
//            startSelection()
//        }
//        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StartSelectionFromHotkey"))) { note in
//            print("[DEBUG] ContentView: StartSelectionFromHotkey received")
//            startSelection()
//            if let completion = note.object as? ((URL?) -> Void) {
//                // startSelection manages UI and saving; we don't provide a URL back
//                completion(nil)
//            }
//        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    activeImporter = .image
                } label: {
                    Label("Open File", systemImage: "doc")
                }
                .keyboardShortcut("o", modifiers: [.command])
                
                Button { showSettingsPopover = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Settings").font(.headline)
                        Divider()
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
                        
                        HStack {
                            Spacer()
                            Button("Close") { showSettingsPopover = false }
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
                    
                    Menu {
                        Button("Flatten & Save", action: flattenAndSaveInPlace)
                        Button("Flatten & Save As…", action: flattenAndSaveAs)
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    } primaryAction: {
                        flattenAndSaveInPlace()
                    }
                    Button(action: { selectedTool = .pointer
                        selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                        focusedTextID = nil
                        
                    }) {
                        Label("Pointer", systemImage: "cursorarrow")
                            .foregroundStyle(selectedTool == .pointer ? Color.white : Color.primary)
                    }
                    .glassEffect(selectedTool == .pointer ? .regular.tint(.blue) : .regular)
                    
                    
                    Menu {
                        Toggle("Arrow", isOn: $lineHasArrow)
                            .toggleStyle(.button)
                        
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
                        Label("Pen", systemImage: lineHasArrow ? "arrow.right" : "pencil.line")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(selectedTool == .line ? Color.white : Color.primary)
                            .tint(selectedTool == .line ? .white : .primary)
                    } primaryAction: {
                        selectedTool = .line
                        selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                        focusedTextID = nil
                        
                    }
                    .glassEffect(selectedTool == .line ? .regular.tint(.blue) : .regular)
                    
                    Menu {
                        Menu("Font Size") {
                            ForEach([10,12,14,16,18,22,26,32,40,48], id: \.self) { s in
                                Button(action: { textFontSize = CGFloat(s) }) {
                                    if Int(textFontSize) == s { Image(systemName: "checkmark") }
                                    Text("\(s) pt")
                                }
                            }
                        }
                        Menu("Text Color") {
                            PenColorButton(current: $textColor, color: .black, name: "Black")
                            PenColorButton(current: $textColor, color: .white, name: "White")
                            PenColorButton(current: $textColor, color: .red, name: "Red")
                            PenColorButton(current: $textColor, color: .blue, name: "Blue")
                            PenColorButton(current: $textColor, color: .systemGreen, name: "Green")
                            PenColorButton(current: $textColor, color: .systemYellow, name: "Yellow")
                        }
                        Toggle("Background", isOn: $textBGEnabled)
                        Menu("Background Color") {
                            PenColorButton(current: $textBGColor, color: .black.withAlphaComponent(0.6), name: "Black 60%")
                            PenColorButton(current: $textBGColor, color: NSColor.white.withAlphaComponent(0.7), name: "White 70%")
                            PenColorButton(current: $textBGColor, color: NSColor.red.withAlphaComponent(0.5), name: "Red 50%")
                            PenColorButton(current: $textBGColor, color: NSColor.blue.withAlphaComponent(0.5), name: "Blue 50%")
                            PenColorButton(current: $textBGColor, color: NSColor.systemGreen.withAlphaComponent(0.5), name: "Green 50%")
                            PenColorButton(current: $textBGColor, color: NSColor.systemYellow.withAlphaComponent(0.5), name: "Yellow 50%")
                        }
                        Divider()
                        
                        Button("Edit Text…") {}
                        
                    } label: {
                        Label("Text", systemImage: "textformat")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(selectedTool == .text ? Color.white : Color.primary)
                            .tint(selectedTool == .text ? .white : .primary)
                    } primaryAction: {
                        selectedTool = .text
                        selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                    }
                    .glassEffect(selectedTool == .text ? .regular.tint(.blue) : .regular)
                    
                    
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
                    } primaryAction: {
                        selectedTool = .rect
                        selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                        focusedTextID = nil
                        
                    }
                    
                    Menu {
                        Menu("Color") {
                            PenColorButton(current: $highlighterColor, color: NSColor.systemYellow.withAlphaComponent(0.35), name: "Yellow 35%")
                            PenColorButton(current: $highlighterColor, color: NSColor.systemGreen.withAlphaComponent(0.35),  name: "Green 35%")
                            PenColorButton(current: $highlighterColor, color: NSColor.systemBlue.withAlphaComponent(0.35),   name: "Blue 35%")
                            PenColorButton(current: $highlighterColor, color: NSColor.systemPink.withAlphaComponent(0.35),   name: "Pink 35%")
                        }
                        Divider()
                        Text("Drag to create translucent box")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Highlighter", systemImage: "highlighter")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(selectedTool == .highlighter ? Color.white : Color.primary)
                            .tint(selectedTool == .highlighter ? .white : .primary)
                    } primaryAction: {
                        selectedTool = .highlighter
                        selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                        focusedTextID = nil
                    }
                    .glassEffect(selectedTool == .highlighter ? .regular.tint(.blue) : .regular)
                    .help("Drag to add a highlight box")
                    
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
                    
                    Menu {
                        Menu("Color") {
                            PenColorButton(current: $badgeColor, color: .systemRed,   name: "Red")
                            PenColorButton(current: $badgeColor, color: .blue,        name: "Blue")
                            PenColorButton(current: $badgeColor, color: .black,       name: "Black")
                            PenColorButton(current: $badgeColor, color: .systemGreen, name: "Green")
                            PenColorButton(current: $badgeColor, color: .systemYellow,name: "Yellow")
                            PenColorButton(current: $badgeColor, color: .white,       name: "White")
                        }
                        Divider()
                        Button("Reset Counter") { badgeCount = 0 }
                    } label: {
                        Label("Badge", systemImage: "1.circle")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(selectedTool == .badge ? Color.white : Color.primary)
                            .tint(selectedTool == .badge ? .white : .primary)
                    } primaryAction: {
                        selectedTool = .badge
                        selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                        focusedTextID = nil
                        
                    }
                    .glassEffect(selectedTool == .badge ? .regular.tint(.blue) : .regular)
                    .help("Click to place numbered badge")
                    
                    
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
                if activeImporter == .folder {
                    if let url = urls.first {
                        saveDirectoryPath = url.path
                        loadExistingSnaps()
                    }
                } else {
                    if let url = urls.first, let img = NSImage(contentsOf: url) {
                        undoStack.removeAll()
                        redoStack.removeAll()
                        lastCapture = img
                        selectedSnapURL = url
                        objects.removeAll()
                        objectSpaceSize = nil
                        selectedObjectID = nil
                        activeHandle = .none
                        cropRect = nil
                        cropDraftRect = nil
                        cropHandle = .none
                        if let dir = snapsDirectory(), url.path.hasPrefix(dir.path) {
                            insertSnapURL(url)
                        }
                    }
                }
            case .failure(let error):
                if activeImporter == .folder {
                    print("Folder selection canceled/failed: \(error)")
                } else {
                    print("Image import canceled/failed: \(error)")
                }
            }
        }
//        .onChange(of: lastCapture) { _, newValue in
//            guard newValue != nil else { return }
//
//            // Add a small delay to ensure the selection overlay is fully dismissed
//            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
//                self.ensureMainEditorWindow()
//            }
//        }
    }
    
    
    @ViewBuilder
    private func selectionForText(_ o: TextObject) -> some View {
        GeometryReader { geo in
            ZStack {
                // Map author's rect to fitted (onscreen) coordinates for the overlay
                let fittedSize = lastFittedSize ?? objectSpaceSize ?? .zero
                let authorSize = objectSpaceSize ?? fittedSize
                let sx = fittedSize.width / max(1, authorSize.width)
                let sy = fittedSize.height / max(1, authorSize.height)
                let rf = CGRect(x: o.rect.origin.x * sx,
                                y: o.rect.origin.y * sy,
                                width: o.rect.size.width * sx,
                                height: o.rect.size.height * sy)
                // Inset (image centered within canvas)
                let ox = max(0, (geo.size.width  - fittedSize.width)  / 2)
                let oy = max(0, (geo.size.height - fittedSize.height) / 2)
                
                // Corner handles (use fitted rect corners + inset)
                let pts = [
                    CGPoint(x: rf.minX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.minX + ox, y: rf.maxY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.maxY + oy)
                ]
                ForEach(Array(pts.enumerated()), id: \.offset) { pair in
                    let pt = pair.element
                    Circle()
                        .stroke(.blue, lineWidth: 1)
                        .background(Circle().fill(.white))
                        .frame(width: 12, height: 12)
                        .position(pt)
                }
                
                // Show inline editor when focused; otherwise show invisible hit area
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
                    .frame(width: rf.width, height: rf.height)
                    .position(x: rf.midX + ox, y: rf.midY + oy)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(.blue.opacity(0.6), lineWidth: 1))
                    .contentShape(Rectangle())
                    .focused($isTextEditorFocused)  // Add this line
                    .onAppear {
                        print("🔥 TextEditor appeared for object \(o.id)")
                        // Automatically focus when appearing
                        DispatchQueue.main.async {
                            isTextEditorFocused = true
                        }
                    }
                    .onChange(of: focusedTextID) { _,newValue in
                        print("🔥 TextEditor focus changed to: \(String(describing: newValue))")
                        // Update focus state when focusedTextID changes
                        isTextEditorFocused = (newValue == o.id)
                    }
                    
                } else {
                    // Invisible hit area for when not editing
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: rf.width, height: rf.height)
                        .position(x: rf.midX + ox, y: rf.midY + oy)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            print("🔥 Double-click on invisible rectangle for object \(o.id)")
                            print("🔥 Before setting: focusedTextID = \(String(describing: focusedTextID))")
                            if selectedObjectID != o.id {
                                selectedObjectID = o.id
                                print("🔥 Set selectedObjectID to \(o.id)")
                            }
                            focusedTextID = o.id
                            print("🔥 After setting: focusedTextID = \(String(describing: focusedTextID))")
                            
                            // Force keyboard focus
                            DispatchQueue.main.async {
                                isTextEditorFocused = true
                            }
                        }
                        .onAppear {
                            print("🔥 Invisible rectangle appeared for object \(o.id)")
                        }
                }
            }
        }
    }
    
    private func badgeGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
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
                let start = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                let current = fittedToAuthorPoint(currentFit, fitted: fitted, author: author)
                
                // If we already have a cropRect, interpret drags as edits (handles or move)
                if let existing = cropRect {
                    if cropDragStart == nil {
                        cropDragStart = start
                        cropOriginalRect = existing
                        // Decide if we're on a handle; otherwise, treat as move if inside rect
                        cropHandle = cropHandleHitTest(existing, at: start)
                        if cropHandle == .none && existing.contains(start) {
                            cropHandle = .none // move
                        }
                    }
                    if let originRect = cropOriginalRect, let s = cropDragStart {
                        if cropHandle == .none && originRect.contains(s) {
                            // Move
                            let dx = current.x - s.x
                            let dy = current.y - s.y
                            var moved = originRect
                            moved.origin.x += dx
                            moved.origin.y += dy
                            cropRect = clampRect(moved, in: author)
                        } else {
                            // Resize using handle
                            cropRect = clampRect(resizeRect(originRect, handle: cropHandle, to: current), in: author)
                        }
                    }
                    return
                }
                
                // No existing cropRect — create a new draft selection
                func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
                    let x0 = min(a.x, b.x)
                    let y0 = min(a.y, b.y)
                    let w = abs(a.x - b.x)
                    let h = abs(a.y - b.y)
                    return CGRect(x: x0, y: y0, width: w, height: h)
                }
                cropDraftRect = rectFrom(start, current)
            }
            .onEnded { value in
                let currentFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                _ = fittedToAuthorPoint(currentFit, fitted: fitted, author: author)
                
                if let _ = cropOriginalRect {
                    // Finish edit
                    cropDragStart = nil
                    cropOriginalRect = nil
                    cropHandle = .none
                    return
                }
                
                // Finish creation
                if let draft = cropDraftRect {
                    let clamped = clampRect(draft, in: author)
                    cropRect = clamped.width > 2 && clamped.height > 2 ? clamped : nil
                }
                cropDraftRect = nil
            }
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
        SelectionWindowManager.shared.present(onComplete: { rect in
            Task {
                if let img = await captureAsync(rect: rect) {
                    undoStack.removeAll(); redoStack.removeAll()
                    lastCapture = img
                    objectSpaceSize = nil
                    objects.removeAll()
                    selectedObjectID = nil
                    activeHandle = .none
                    
                    if let savedURL = saveSnapToDisk(img) {
                        insertSnapURL(savedURL)
                        selectedSnapURL = savedURL
                    }
                    //copyToPasteboard(img)
                    
                    // Bring app to foreground after capture
                    DispatchQueue.main.async {
                        // Force app activation first
                        NSApp.activate(ignoringOtherApps: true)
                        
                        // Try to bring existing window to front
                        WindowManager.shared.bringToFront()
                        
                        // If no window was found, create one
                        if !WindowManager.shared.hasVisibleWindows() {
                            self.ensureMainEditorWindow()
                        }
                    }
                    
//                    withAnimation { showCopiedHUD = true }
//                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
//                        withAnimation { showCopiedHUD = false }
//                    }
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
            let scale = bestScreen.backingScaleFactor
            let pxPerPtX = scale
            let pxPerPtY = scale
            
            print("🔍 Scale Factor Debug:")
            print("  scDisplay.width: \(scDisplay.width)")
            print("  scDisplay.height: \(scDisplay.height)")
            print("  screenFramePts.width: \(screenFramePts.width)")
            print("  screenFramePts.height: \(screenFramePts.height)")
            print("  bestScreen.backingScaleFactor: \(bestScreen.backingScaleFactor)")
            
            // 4) Build a filter for that display and capture one frame.
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            guard let fullCG = await ScreenCapturer.shared.captureImage(using: filter, display: scDisplay) else { return nil }
            print("Full capture dimensions: \(fullCG.width) × \(fullCG.height)")
            print("Expected for 5K display: should be around 5120 × 2880")
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

            let rep = NSBitmapImageRep(cgImage: cropped)
            let pointSize = CGSize(
                width: CGFloat(cropped.width) / pxPerPtX,
                height: CGFloat(cropped.height) / pxPerPtY
            )
            rep.size = pointSize

            let nsImage = NSImage(size: pointSize)
            nsImage.addRepresentation(rep)

            // Debug logging
            print("🔍 Capture Debug:")
            print("  Screen scale factors: pxPerPtX=\(pxPerPtX), pxPerPtY=\(pxPerPtY)")
            print("  CGImage pixel size: \(cropped.width) × \(cropped.height)")
            print("  Calculated point size: \(pointSize.width) × \(pointSize.height)")
            print("  NSImage.size: \(nsImage.size.width) × \(nsImage.size.height)")
            print("  Rep.size: \(rep.size.width) × \(rep.size.height)")
            print("  Rep pixels: \(rep.pixelsWide) × \(rep.pixelsHigh)")

            return nsImage
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
        
        withAnimation { showCopiedHUD = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { showCopiedHUD = false }
        }
        
    }
    
    private func pushUndoSnapshot() {
        undoStack.append(Snapshot(image: lastCapture, objects: objects))
        redoStack.removeAll()
    }
    
    // MARK: - Save / Save As
    
    private func defaultSnapFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return "snap_\(formatter.string(from: Date())).\(preferredSaveFormat.fileExtension)"
    }
    
    
    @discardableResult
    private func writeImage(_ image: NSImage, to url: URL, format: SaveFormat, jpegQuality: CGFloat? = nil) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return false }
        
        let data: Data?
        switch format {
        case .png:
            data = rep.representation(using: .png, properties: [:])
        case .jpeg:
            let q = (jpegQuality ?? 0.9)
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: q])
        case .heic:
            guard let cgimg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                data = nil
                break
            }
            let mutable = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                mutable as CFMutableData,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else {
                data = nil
                break
            }
            
            let q = (jpegQuality ?? 0.9) as CGFloat
            // Pass lossy compression quality (0.0 ... 1.0)
            let props: CFDictionary = [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary
            CGImageDestinationAddImage(dest, cgimg, props)
            
            data = CGImageDestinationFinalize(dest) ? (mutable as Data) : nil
        }
        
        guard let data else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
    
    /// Save As… — prompts for a destination, updates gallery if under snaps folder.
    private func saveAsCurrent() {
        guard let img = lastCapture else { return }
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
            panel.nameFieldStringValue = defaultSnapFilename()
        } else {
            panel.nameFieldStringValue = defaultSnapFilename()
        }
        if panel.runModal() == .OK, let url = panel.url {
            if writeImage(img, to: url, format: preferredSaveFormat, jpegQuality: CGFloat(saveQuality)) {
                selectedSnapURL = url
                refreshGalleryAfterSaving(to: url)
            }
        }
    }
    
    /// Save — overwrites the currently selected snap if available, else falls back to Save As….
    private func saveCurrentOverwrite() {
        guard let img = lastCapture else { return }
        if let url = selectedSnapURL {
            if writeImage(img, to: url, format: preferredSaveFormat, jpegQuality: CGFloat(saveQuality)) {
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
    
    
    private func lineGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let pRaw = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let sRaw = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let pA = fittedToAuthorPoint(pRaw, fitted: fitted, author: author)
                let sA = fittedToAuthorPoint(sRaw, fitted: fitted, author: author)
                if draft == nil { draft = Line(start: sA, end: pA, width: strokeWidth) }
                let shift = NSEvent.modifierFlags.contains(.shift)
                if let start = draft?.start {
                    draft?.end = shift ? snappedPoint(start: start, raw: pA) : pA
                }
                draft?.width = strokeWidth
            }
            .onEnded { value in
                let pRaw = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let shift = NSEvent.modifierFlags.contains(.shift)
                guard let start = draft?.start else { draft = nil; return }
                let pA = fittedToAuthorPoint(pRaw, fitted: fitted, author: author)
                let endUI = shift ? snappedPoint(start: start, raw: pA) : pA
                let s = clampPoint(start, in: author)
                let e = clampPoint(endUI, in: author)
                let newObj = LineObject(start: s, end: e, width: strokeWidth, arrow: lineHasArrow)
                pushUndoSnapshot()
                objects.append(.line(newObj))
                if objectSpaceSize == nil { objectSpaceSize = author }
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
    
    private func rectGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let currentFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let start = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                let current = fittedToAuthorPoint(currentFit, fitted: fitted, author: author)
                let shift = NSEvent.modifierFlags.contains(.shift)
                
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
            .onEnded { value in
                defer { draftRect = nil }
                guard let uiRect = draftRect else { return }
                let clamped = clampRect(uiRect, in: author)
                let newObj = RectObject(rect: clamped, width: strokeWidth)
                pushUndoSnapshot()
                objects.append(.rect(newObj))
                if objectSpaceSize == nil { objectSpaceSize = author }
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
                let shift = NSEvent.modifierFlags.contains(.shift)
                
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
            .onEnded { _ in
                defer { draftRect = nil }
                guard let uiRect = draftRect else { return }
                let clamped = clampRect(uiRect, in: author)
                let newObj = HighlightObject(rect: clamped, color: highlighterColor)
                pushUndoSnapshot()
                objects.append(.highlight(newObj))
                if objectSpaceSize == nil { objectSpaceSize = author }
            }
    }
    
    private func textGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
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
                let pFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let p = fittedToAuthorPoint(pFit, fitted: fitted, author: author)
                if dragStartPoint == nil {
                    dragStartPoint = p
                    if let idx = objects.firstIndex(where: { obj in
                        switch obj {
                        case .line(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .rect(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
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
                
                // Check for double-click
                print("🔥 Pointer gesture ended, moved: \(moved)")
                if let event = NSApp.currentEvent {
                    print("🔥 Click count: \(event.clickCount)")
                } else {
                    print("🔥 No current event")
                }
                
                let isDoubleClick = if let event = NSApp.currentEvent {
                    event.clickCount >= 2
                } else {
                    false
                }
                
                print("🔥 Is double click: \(isDoubleClick)")
                
                if !moved && isDoubleClick {
                    print("🔥 Processing double-click logic")
                    print("🔥 Current focusedTextID before change: \(String(describing: focusedTextID))")
                    // Check ALL text objects, not just selected ones
                    for (index, obj) in objects.enumerated() {
                        if case .text(let textObj) = obj {
                            let hit = textObj.hitTest(pEnd)
                            print("🔥 Text object \(index) hit test: \(hit), rect: \(textObj.rect)")
                            if hit {
                                print("🔥 Setting focus to text object \(index)")
                                selectedObjectID = textObj.id
                                focusedTextID = textObj.id
                                print("🔥 focusedTextID after setting: \(String(describing: focusedTextID))")
                                break
                            }
                        }
                    }
                }
                
                dragStartPoint = nil
                pushedDragUndo = false
            }    }
    
    // MARK: - Commit & Undo/Redo
    private func commitChange(_ newImage: NSImage) {
        lastCapture = newImage
    }
    @ViewBuilder private func selectionForLine(_ o: LineObject) -> some View {
        GeometryReader { geo in
            ZStack {
                // Map author-space endpoints to fitted (onscreen) coordinates
                let fittedSize = lastFittedSize ?? objectSpaceSize ?? .zero
                let authorSize = objectSpaceSize ?? fittedSize
                let sx = fittedSize.width / max(1, authorSize.width)
                let sy = fittedSize.height / max(1, authorSize.height)
                let sF = CGPoint(x: o.start.x * sx, y: o.start.y * sy)
                let eF = CGPoint(x: o.end.x   * sx, y: o.end.y   * sy)
                
                // Inset (image centered within canvas)
                let ox = max(0, (geo.size.width  - fittedSize.width)  / 2)
                let oy = max(0, (geo.size.height - fittedSize.height) / 2)
                
                // Endpoint handles (in fitted space + inset)
                Circle().stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(x: sF.x + ox, y: sF.y + oy)
                
                Circle().stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(x: eF.x + ox, y: eF.y + oy)
            }
        }
    }
    
    @ViewBuilder private func selectionForRect(_ o: RectObject) -> some View {
        GeometryReader { geo in
            ZStack {
                // Map author rect to fitted (onscreen) coordinates
                let fittedSize = lastFittedSize ?? objectSpaceSize ?? .zero
                let authorSize = objectSpaceSize ?? fittedSize
                let sx = fittedSize.width / max(1, authorSize.width)
                let sy = fittedSize.height / max(1, authorSize.height)
                let rf = CGRect(x: o.rect.origin.x * sx,
                                y: o.rect.origin.y * sy,
                                width: o.rect.size.width * sx,
                                height: o.rect.size.height * sy)
                // Inset (image centered within canvas)
                let ox = max(0, (geo.size.width  - fittedSize.width)  / 2)
                let oy = max(0, (geo.size.height - fittedSize.height) / 2)
                
                // Corner handles in fitted space + inset
                let pts = [
                    CGPoint(x: rf.minX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.minX + ox, y: rf.maxY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.maxY + oy)
                ]
                ForEach(Array(pts.enumerated()), id: \.offset) { pair in
                    let pt = pair.element
                    Circle()
                        .stroke(.blue, lineWidth: 1)
                        .background(Circle().fill(.white))
                        .frame(width: 12, height: 12)
                        .position(pt)
                }
            }
        }
    }
    
    @ViewBuilder private func selectionForHighlight(_ o: HighlightObject) -> some View {
        GeometryReader { geo in
            ZStack {
                let fittedSize = lastFittedSize ?? objectSpaceSize ?? .zero
                let authorSize = objectSpaceSize ?? fittedSize
                let sx = fittedSize.width / max(1, authorSize.width)
                let sy = fittedSize.height / max(1, authorSize.height)
                let rf = CGRect(x: o.rect.origin.x * sx,
                                y: o.rect.origin.y * sy,
                                width: o.rect.size.width * sx,
                                height: o.rect.size.height * sy)
                let ox = max(0, (geo.size.width  - fittedSize.width)  / 2)
                let oy = max(0, (geo.size.height - fittedSize.height) / 2)
                let pts = [
                    CGPoint(x: rf.minX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.minX + ox, y: rf.maxY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.maxY + oy)
                ]
                ForEach(Array(pts.enumerated()), id: \.offset) { pair in
                    let pt = pair.element
                    Circle()
                        .stroke(.blue, lineWidth: 1)
                        .background(Circle().fill(.white))
                        .frame(width: 12, height: 12)
                        .position(pt)
                }
            }
        }
    }
    
    @ViewBuilder private func selectionForBadge(_ o: BadgeObject) -> some View {
        GeometryReader { geo in
            ZStack {
                // Map author rect to fitted (onscreen) coordinates
                let fittedSize = lastFittedSize ?? objectSpaceSize ?? .zero
                let authorSize = objectSpaceSize ?? fittedSize
                let sx = fittedSize.width / max(1, authorSize.width)
                let sy = fittedSize.height / max(1, authorSize.height)
                let rf = CGRect(x: o.rect.origin.x * sx,
                                y: o.rect.origin.y * sy,
                                width: o.rect.size.width * sx,
                                height: o.rect.size.height * sy)
                
                // Inset (image centered within canvas)
                let ox = max(0, (geo.size.width  - fittedSize.width)  / 2)
                let oy = max(0, (geo.size.height - fittedSize.height) / 2)
                
                // Corner handles in fitted space + inset (same look as rect/text)
                let pts = [
                    CGPoint(x: rf.minX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.minX + ox, y: rf.maxY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.maxY + oy)
                ]
                ForEach(Array(pts.enumerated()), id: \.offset) { pair in
                    let pt = pair.element
                    Circle()
                        .stroke(.blue, lineWidth: 1)
                        .background(Circle().fill(.white))
                        .frame(width: 12, height: 12)
                        .position(pt)
                }
            }
        }
    }
    
    @ViewBuilder private func selectionForImage(_ o: PastedImageObject) -> some View {
        GeometryReader { geo in
            ZStack {
                let fittedSize = lastFittedSize ?? objectSpaceSize ?? .zero
                let authorSize = objectSpaceSize ?? fittedSize
                let sx = fittedSize.width / max(1, authorSize.width)
                let sy = fittedSize.height / max(1, authorSize.height)
                let rf = CGRect(x: o.rect.origin.x * sx,
                                y: o.rect.origin.y * sy,
                                width: o.rect.size.width * sx,
                                height: o.rect.size.height * sy)
                
                let ox = max(0, (geo.size.width  - fittedSize.width)  / 2)
                let oy = max(0, (geo.size.height - fittedSize.height) / 2)
                
                let pts = [
                    CGPoint(x: rf.minX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.minY + oy),
                    CGPoint(x: rf.minX + ox, y: rf.maxY + oy),
                    CGPoint(x: rf.maxX + ox, y: rf.maxY + oy)
                ]
                ForEach(Array(pts.enumerated()), id: \.offset) { pair in
                    let pt = pair.element
                    Circle()
                        .stroke(.blue, lineWidth: 1)
                        .background(Circle().fill(.white))
                        .frame(width: 12, height: 12)
                        .position(pt)
                }
            }
        }
    }
    
    private func flattenAndSaveInPlace() {
        guard let img = lastCapture else { return }
        if objectSpaceSize == nil { objectSpaceSize = lastFittedSize ?? img.size }
        pushUndoSnapshot()
        if let flattened = rasterize(base: img, objects: objects) {
            lastCapture = flattened
            objects.removeAll()
            if let url = selectedSnapURL {
                if writeImage(flattened, to: url, format: preferredSaveFormat, jpegQuality: CGFloat(saveQuality)) {
                    refreshGalleryAfterSaving(to: url)
                }
            } else {
                saveAsCurrent()
            }
        }
    }
    
    private func flattenAndSaveAs() {
        guard let img = lastCapture else { return }
        if objectSpaceSize == nil { objectSpaceSize = lastFittedSize ?? img.size }
        pushUndoSnapshot()
        if let flattened = rasterize(base: img, objects: objects) {
            lastCapture = flattened
            objects.removeAll()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [preferredSaveFormat.utType]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = selectedSnapURL?.lastPathComponent ?? defaultSnapFilename()
            if panel.runModal() == .OK, let url = panel.url {
                if writeImage(flattened, to: url, format: preferredSaveFormat, jpegQuality: CGFloat(saveQuality)) {
                    selectedSnapURL = url
                    refreshGalleryAfterSaving(to: url)
                }
            }
        }
    }
    
    private func rasterize(base: NSImage, objects: [Drawable]) -> NSImage? {
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
        strokeColor.setStroke(); strokeColor.setFill()
        
        // Use the objectSpaceSize (UI space) that objects were laid out in; fall back to lastFittedSize or image size if unknown
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
                let path = NSBezierPath(); path.lineWidth = widthScaled; path.lineCapStyle = .round
                path.move(to: s); path.line(to: e); path.stroke()
                if o.arrow {
                    let dx = e.x - s.x, dy = e.y - s.y
                    let len = max(1, hypot(dx, dy))
                    let headLength = min(len * 0.8, max(10, 6 * widthScaled))
                    let headWidth  = max(8, 5 * widthScaled)
                    let ux = dx/len, uy = dy/len
                    let bx = e.x - ux * headLength, by = e.y - uy * headLength
                    let px = -uy, py = ux
                    let p1 = CGPoint(x: bx + px * (headWidth/2), y: by + py * (headWidth/2))
                    let p2 = CGPoint(x: bx - px * (headWidth/2), y: by - py * (headWidth/2))
                    let tri = NSBezierPath(); tri.move(to: e); tri.line(to: p1); tri.line(to: p2); tri.close(); tri.fill()
                }
            case .rect(let o):
                let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                let path = NSBezierPath(rect: r); path.lineWidth = o.width * scaleW; path.stroke()
            case .text(let o):
                let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                if o.bgEnabled {
                    let bgPath = NSBezierPath(rect: r)
                    o.bgColor.setFill()
                    bgPath.fill()
                }
                let para = NSMutableParagraphStyle()
                para.alignment = .left
                para.lineBreakMode = .byWordWrapping
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: o.fontSize * scaleW),
                    .foregroundColor: o.textColor,
                    .paragraphStyle: para
                ]
                NSString(string: o.text).draw(in: r.insetBy(dx: 4 * scaleW, dy: 4 * scaleW), withAttributes: attrs)
                
            case .badge(let o):
                let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                let circlePath = NSBezierPath(ovalIn: r)
                o.fillColor.setFill()
                circlePath.fill()
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
                o.color.setFill()
                NSBezierPath(rect: r).fill()
            case .image(let o):
                let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                o.image.draw(in: r)
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
        let current = Snapshot(image: lastCapture, objects: objects)
        redoStack.append(current)
        lastCapture = prev.image
        objects = prev.objects
    }
    
    private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        let current = Snapshot(image: lastCapture, objects: objects)
        undoStack.append(current)
        lastCapture = next.image
        objects = next.objects
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
            let author = objectSpaceSize ?? lastFittedSize ?? lastCapture?.size ?? CGSize(width: 1200, height: 800)
            
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
    
    @State private var openEditorAfterCapture: Bool = false
    
    private func saveSnapToDisk(_ image: NSImage) -> URL? {
        guard let dir = snapsDirectory() else { return nil }
        let url = dir.appendingPathComponent(defaultSnapFilename())
        if writeImage(image, to: url, format: preferredSaveFormat, jpegQuality: CGFloat(saveQuality)) {
            // Insert at head of recent list
            insertSnapURL(url)
            // If the hotkey initiated this capture (window may be closed), open the editor with the new snap
            if openEditorAfterCapture {
                let img = image
                selectedSnapURL = url
                lastCapture = img
                presentEditor(url: url, image: img)
                openEditorAfterCapture = false
            }
            return url
        } else {
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
            snapURLs = Array(sorted.prefix(10))
            
            // Clean up missing URLs from our tracking set
            missingSnapURLs = missingSnapURLs.filter { !sorted.contains($0) }
            
            // If currently selected snap no longer exists, clear selection
            if let sel = selectedSnapURL, !sorted.contains(sel) {
                selectedSnapURL = nil
                lastCapture = nil
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
                if let img = NSImage(contentsOf: url) {
                    selectedSnapURL = url
                    lastCapture = img
                    GalleryWindow.shared.close()
                }
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
        @State private var image: NSImage? = nil

        var body: some View {
            ZStack {
                if let img = image {
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
            // Simple selection border
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: selected ? 2 : 1)
            )
            // Hover controls + selected checkmark
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                    .opacity(hovering ? 1 : 0.001)
                    .allowsHitTesting(hovering)
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
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
                .padding(4)
            }
            .onAppear {
                if image == nil {
                    image = NSImage(contentsOf: url)
                }
            }
            .onChange(of: url) { _, newURL in
                image = NSImage(contentsOf: newURL)
            }
        }
    }
    

    
}


// MARK: - Preload initializer for opening editor with an image
//extension ContentView {
//    init(preloadURL: URL?, preloadImage: NSImage?) {
//        //self.init()
//        
//        self._selectedSnapURL = State(initialValue: preloadURL)
//        self._lastCapture = State(initialValue: preloadImage)
//        self._snapURLs = State(initialValue: [])
//        self.init()
//        _selectedSnapURL = State(initialValue: preloadURL)
//        _lastCapture = State(initialValue: preloadImage)
//    }
//}

// MARK: - Root View Modifier for Global Hotkey

extension ContentView {
    
    /// Ensures a main editor window is present and visible, creating one if necessary
    private func ensureMainEditorWindow() {
        DispatchQueue.main.async {
            // Look for ANY existing ContentView windows
            for window in NSApp.windows {
                if let _ = window.contentViewController as? NSHostingController<ContentView>,
                   window.styleMask.contains(.titled),
                   !window.isSheet {
                    
                    // If minimized, deminiaturize first
                    if window.isMiniaturized {
                        window.deminiaturize(nil)
                    }
                    
                    // DON'T refresh the rootView - just bring the existing window forward
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    NSApp.activate(ignoringOtherApps: true)
                    return
                }
            }
            
            // Only create new window if no suitable window exists
            self.createNewMainEditorWindow()
        }
    }
    
    /// Creates a new main editor window with proper setup
    private func createNewMainEditorWindow(preloadURL: URL? = nil, preloadImage: NSImage? = nil) {
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.tabbingMode = .disallowed
        newWindow.isReleasedWhenClosed = false
        newWindow.contentMinSize = NSSize(width: 900, height: 600)
        newWindow.title = "Screen Snap"
        
        // Create a fresh ContentView instance for the new window
        let newContentView = ContentView()
        newWindow.contentViewController = NSHostingController(rootView: newContentView)
        
        // Set up window controller for better management
        let windowController = NSWindowController(window: newWindow)
        windowController.windowFrameAutosaveName = "MainEditorWindow"
        
        // Center and show the window
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
        
        // Force app activation
        NSApp.activate(ignoringOtherApps: true)
        
        // Store reference to prevent deallocation
        WindowManager.shared.registerWindow(windowController)
    }

    /// Presents the editor with the given image. Reuses existing window if available; otherwise creates a new one preloaded.
    private func presentEditor(url: URL?, image: NSImage?) {
        // Try to find an existing ContentView-hosting window first
        for window in NSApp.windows {
            if let hosting = window.contentViewController as? NSHostingController<ContentView>,
               window.styleMask.contains(.titled),
               !window.isSheet {
                
                // Just bring the existing window forward and let it load the new snap normally
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                
                // Post a notification to load the specific snap
                if let url = url {
                    NotificationCenter.default.post(
                        name: Notification.Name("LoadSpecificSnap"),
                        object: url
                    )
                }
                return
            }
        }
        
        // No existing window — create a new one and load the snap after creation
        createNewMainEditorWindow()
        
        // Post notification to load the snap after window creation
        if let url = url {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(
                    name: Notification.Name("LoadSpecificSnap"),
                    object: url
                )
            }
        }
    }
}


// MARK: - Geometry/Screen Helpers

private func screenForGlobalRect(_ r: CGRect) -> NSScreen? {
    // Pick the screen with the largest intersection area with the selection rect
    NSScreen.screens.max { a, b in
        a.frame.intersection(r).area < b.frame.intersection(r).area
    }
}


// MARK: - Gallery Window + View

/// Simple NSWindow wrapper to present a SwiftUI gallery of thumbnails.
private final class GalleryWindow {
    static let shared = GalleryWindow()
    private var window: NSWindow?
    private var windowDelegate: NSWindowDelegate?
    private var controller: NSWindowController?
    private let frameDefaultsKey = "SnapGalleryManualFrame"

    func present(urls: [URL], onSelect: @escaping (URL) -> Void, onReload: @escaping () -> [URL]) {
        // If already visible, just bring to front and update content
        if let win = window {
            // Refresh content in the existing window
            if let hosting = win.contentViewController as? NSHostingController<GalleryView> {
                hosting.rootView = GalleryView(urls: urls, onSelect: onSelect, onReload: onReload)
            } else {
                win.contentViewController = NSHostingController(rootView: GalleryView(urls: urls, onSelect: onSelect, onReload: onReload))
            }
            // Enforce a sane size if it somehow got too small
            win.minSize = NSSize(width: 480, height: 360)
            var f = win.frame
            if f.width < 600 || f.height < 400 {
                f.size.width = max(f.width, 820)
                f.size.height = max(f.height, 620)
                win.setFrame(f, display: false)
            }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = GalleryView(urls: urls, onSelect: onSelect, onReload: onReload)
        let hosting = NSHostingController(rootView: content)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        //win.titleVisibility = .hidden
        win.title = "Snap Gallery"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.tabbingMode = .disallowed
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 900, height: 600)
        win.contentViewController = hosting

        // Create controller and set up autosave through the controller
        let controller = NSWindowController(window: win)
        let autosaveName = "SnapGalleryWindowV2"
        controller.windowFrameAutosaveName = autosaveName

        // Only use the controller's autosave mechanism - remove conflicting calls
        // Remove: win.setFrameAutosaveName(autosaveName)
        // Remove: win.setFrameUsingName(autosaveName)

        self.controller = controller
        self.window = win

        // Set up close handler
        let closeHandler = WindowCloseHandler(key: frameDefaultsKey) { [weak self] in
            self?.window = nil
            self?.controller = nil
            self?.windowDelegate = nil
        }
        win.delegate = closeHandler
        self.windowDelegate = closeHandler

        // Show the window - this will trigger automatic frame restoration
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Post-show validation and adjustment
        DispatchQueue.main.async {
            let minW: CGFloat = 900
            let minH: CGFloat = 600
            let vf = (win.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = win.frame
            let tooSmall = frame.width < minW || frame.height < minH
            let padding: CGFloat = 20
            let safeVisible = vf.insetBy(dx: padding, dy: padding)
            let center = NSPoint(x: frame.midX, y: frame.midY)
            let offscreen = !safeVisible.contains(center)

            if tooSmall || offscreen {
                let targetW = max(minW, min(vf.width * 0.8, 1800))
                let targetH = max(minH, min(vf.height * 0.85, 1200))
                let targetX = vf.midX - targetW / 2
                let targetY = vf.midY - targetH / 2
                win.setFrame(NSRect(x: targetX, y: targetY, width: targetW, height: targetH), display: true)
            }
        }
    }

    // Also update the WindowCloseHandler to not save manually since autosave handles it
    private final class WindowCloseHandler: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        let key: String // Keep for compatibility but don't use
        
        init(key: String, onClose: @escaping () -> Void) {
            self.key = key
            self.onClose = onClose
        }
        
        func windowWillClose(_ notification: Notification) {
            // Remove manual frame saving - let autosave handle it
            // if let win = notification.object as? NSWindow {
            //     let rectString = NSStringFromRect(win.frame)
            //     UserDefaults.standard.set(rectString, forKey: key)
            // }
            onClose()
        }
    }
    func close() {
        window?.close()
        window = nil
    }
    
}

/// SwiftUI gallery view: scrollable grid of thumbnails that calls `onSelect(url)` when tapped.
private struct GalleryView: View {
    let onSelect: (URL) -> Void
    let onReload: () -> [URL]
    @State private var urlsLocal: [URL]

    @AppStorage("saveDirectoryPath") private var saveDirectoryPath: String = ""

    private func snapsDirectoryFromSettings() -> URL? {
        if !saveDirectoryPath.isEmpty {
            return URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        }
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

    private func openSnapsInFinder() {
        guard let dir = snapsDirectoryFromSettings() else { return }
        NSWorkspace.shared.open(dir)
    }

    init(urls: [URL], onSelect: @escaping (URL) -> Void, onReload: @escaping () -> [URL]) {
        self.onSelect = onSelect
        self.onReload = onReload
        _urlsLocal = State(initialValue: urls)
    }

    // Basic grid: adapts to window size
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 180), spacing: 10)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(urlsLocal, id: \.self) { url in
                    GalleryThumb(url: url)
                        .onTapGesture { onSelect(url) }
                }
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    urlsLocal = onReload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Button {
                    openSnapsInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity,
               minHeight: 360, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// A single thumbnail cell with a quick NSImage load.
private struct GalleryThumb: View {
    let url: URL
    @State private var image: NSImage? = nil
    
    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.12))
                    Image(systemName: "photo")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 180, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.35), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if image == nil {
                image = NSImage(contentsOf: url)
            }
        }
        .help(url.lastPathComponent)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
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

private protocol DrawableObject: Identifiable, Equatable {
    func drawPath(in size: CGSize) -> Path
    func hitTest(_ p: CGPoint) -> Bool
    func handleHitTest(_ p: CGPoint) -> Handle
    func moved(by delta: CGSize) -> Self
    func resizing(_ handle: Handle, to p: CGPoint) -> Self
}

private struct LineObject: DrawableObject {
    let id: UUID
    var start: CGPoint
    var end: CGPoint
    var width: CGFloat
    var arrow: Bool
    
    init(id: UUID = UUID(), start: CGPoint, end: CGPoint, width: CGFloat, arrow: Bool) {
        self.id = id; self.start = start; self.end = end; self.width = width; self.arrow = arrow
    }
    
    static func == (lhs: LineObject, rhs: LineObject) -> Bool { lhs.id == rhs.id && lhs.start == rhs.start && lhs.end == rhs.end && lhs.width == rhs.width && lhs.arrow == rhs.arrow }
    
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
    
    init(id: UUID = UUID(), rect: CGRect, width: CGFloat) { self.id = id; self.rect = rect; self.width = width }
    
    static func == (lhs: RectObject, rhs: RectObject) -> Bool { lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.width == rhs.width }
    
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
    
    func drawPath(in _: CGSize) -> Path { Rectangle().path(in: rect) }
    
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
    
    func drawPath(in _: CGSize) -> Path { Rectangle().path(in: rect) }
    
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
    
    func drawPath(in _: CGSize) -> Path { Circle().path(in: rect) }
    
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
    
    func drawPath(in _: CGSize) -> Path { Rectangle().path(in: rect) }
    
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
    
    var id: UUID {
        switch self {
        case .line(let o): return o.id
        case .rect(let o): return o.id
        case .text(let o): return o.id
        case .badge(let o): return o.id
        case .highlight(let o): return o.id
        case .image(let o): return o.id
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

private struct Box: Identifiable {
    let id = UUID()
    var rect: CGRect
    var width: CGFloat
}


final class ScreenCapturer: NSObject, SCStreamOutput {
    static let shared = ScreenCapturer()
    
    private var currentStream: SCStream?
    private var captureResult: CGImage?
    private var captureError: Error?
    private var isCapturing = false
    
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
            
            return await performCapture(filter: filter, config: config)
        } catch {
            return nil
        }
    }
    
    func captureImage(using filter: SCContentFilter, display: SCDisplay) async -> CGImage? {
        let cfg = SCStreamConfiguration()
        
        let backingScale = getBackingScaleForDisplay(display) ?? 1.0
        cfg.width = Int(CGFloat(display.width) * backingScale)
        cfg.height = Int(CGFloat(display.height) * backingScale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        
        print("Display backing scale: \(backingScale), forcing capture size to: \(cfg.width) × \(cfg.height)")
        
        return await performCapture(filter: filter, config: cfg)
    }
    
    private func performCapture(filter: SCContentFilter, config: SCStreamConfiguration) async -> CGImage? {
        // Prevent concurrent captures
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        
        // Reset state
        captureResult = nil
        captureError = nil
        currentStream = nil
        
        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            currentStream = stream
            
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            
            // Wait for result with timeout using polling
            let startTime = CACurrentMediaTime()
            let timeout: TimeInterval = 4.0
            
            while captureResult == nil && captureError == nil {
                if CACurrentMediaTime() - startTime > timeout {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms polling
            }
            
            // Clean shutdown
            await shutdownStream(stream)
            
            if let error = captureError {
                throw error
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
                onCancel: { self.dismiss() }
            )
            .ignoresSafeArea()

            panel.contentView = NSHostingView(rootView: root)
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
            NSLog("[DEBUG] Selection complete rect")
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



// Scales a Drawable from an old UI space to a new one (non-uniform allowed).
private func scaleDrawable(_ d: Drawable, sx: CGFloat, sy: CGFloat) -> Drawable {
    let avgScale = (sx + sy) / 2
    switch d {
    case .line(let o):
        var c = o
        c.start.x *= sx; c.start.y *= sy
        c.end.x   *= sx; c.end.y   *= sy
        c.width   = max(1, c.width * avgScale)
        return .line(c)
    case .rect(let o):
        var c = o
        c.rect.origin.x *= sx; c.rect.origin.y *= sy
        c.rect.size.width  *= sx; c.rect.size.height *= sy
        c.width = max(1, c.width * avgScale)
        return .rect(c)
    case .text(let o):
        var c = o
        c.rect.origin.x *= sx; c.rect.origin.y *= sy
        c.rect.size.width  *= sx; c.rect.size.height *= sy
        c.fontSize = max(6, c.fontSize * avgScale)
        return .text(c)
    case .badge(let o):
        var c = o
        c.rect.origin.x *= sx; c.rect.origin.y *= sy
        c.rect.size.width  *= sx; c.rect.size.height *= sy
        // Keep badge roughly square after non-uniform scaling
        let side = max(8, (c.rect.width + c.rect.height) / 2)
        c.rect.size = CGSize(width: side, height: side)
        return .badge(c)
    case .highlight(let o):
        var c = o
        c.rect.origin.x *= sx; c.rect.origin.y *= sy
        c.rect.size.width  *= sx; c.rect.size.height *= sy
        return .highlight(c)
    case .image(let o):
        var c = o
        c.rect.origin.x *= sx; c.rect.origin.y *= sy
        c.rect.size.width  *= sx; c.rect.size.height *= sy
        return .image(c)
    }
}

private func fittedToAuthorPoint(_ p: CGPoint, fitted: CGSize, author: CGSize) -> CGPoint {
    let sx = author.width / max(1, fitted.width)
    let sy = author.height / max(1, fitted.height)
    return CGPoint(x: p.x * sx, y: p.y * sy)
}
private func fittedToAuthorRect(_ r: CGRect, fitted: CGSize, author: CGSize) -> CGRect {
    let sx = author.width / max(1, fitted.width)
    let sy = author.height / max(1, fitted.height)
    return CGRect(x: r.origin.x * sx, y: r.origin.y * sy, width: r.size.width * sx, height: r.size.height * sy)
}


/// Crops an NSImage using a rect expressed in image coordinates with bottom-left origin.
private func cropImage(_ image: NSImage, toBottomLeftRect rBL: CGRect) -> NSImage? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let imgH = CGFloat(cg.height)
    // Convert to CoreGraphics top-left origin
    let rectTL = CGRect(x: rBL.origin.x,
                        y: imgH - (rBL.origin.y + rBL.height),
                        width: rBL.width,
                        height: rBL.height).integral
    guard rectTL.width > 1, rectTL.height > 1 else { return nil }
    guard let sub = cg.cropping(to: rectTL) else { return nil }
    return NSImage(cgImage: sub, size: NSSize(width: rectTL.width, height: rectTL.height))
}


final class WindowManager {
    static let shared = WindowManager()
    private var windowControllers: Set<NSWindowController> = []
    
    private init() {
        setupAppBehavior()
    }
    
    func registerWindow(_ controller: NSWindowController) {
        windowControllers.insert(controller)
        
        // Set up cleanup when window closes
        if let window = controller.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                if let closingWindow = notification.object as? NSWindow,
                   let closingController = self?.windowControllers.first(where: { $0.window === closingWindow }) {
                    self?.windowControllers.remove(closingController)
                }
            }
        }
    }
    
    func hasVisibleWindows() -> Bool {
        for window in NSApp.windows {
            if window.title == "Screen Snap" &&
               window.styleMask.contains(.titled) &&
               !window.isSheet &&
               window.isVisible &&
               !window.isMiniaturized {
                return true
            }
        }
        return false
    }

    func bringToFront() {
        for window in NSApp.windows {
            if window.title == "Screen Snap" &&
               window.styleMask.contains(.titled) &&
               !window.isSheet {
                
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }
    }
    
    private func setupAppBehavior() {
        // This would be handled by your app delegate
    }
}
