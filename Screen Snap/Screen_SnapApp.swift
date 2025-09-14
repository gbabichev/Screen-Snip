//
//  Screen_SnapApp.swift
//  Screen Snap
//


import SwiftUI
import Carbon.HIToolbox
import ScreenCaptureKit
import UniformTypeIdentifiers
import Combine

enum ToolKind: String {
    case pointer
    case pen
    case arrow
    case highlighter
    case rect
    case oval
    case increment
    case text
    case crop
}

extension Notification.Name {
    static let selectTool = Notification.Name("com.georgebabichev.screensnap.selectTool")
    static let openImageFile = Notification.Name("com.georgebabichev.screensnap.openImageFile")
    static let copyToClipboard = Notification.Name("com.georgebabichev.screensnap.copyToClipboard")
    static let performUndo = Notification.Name("com.georgebabichev.screensnap.performUndo")
    static let performRedo = Notification.Name("com.georgebabichev.screensnap.performRedo")
    static let saveImage = Notification.Name("com.georgebabichev.screensnap.saveImage")
    static let saveAsImage = Notification.Name("com.georgebabichev.screensnap.saveAsImage")
    static let zoomIn = Notification.Name("com.georgebabichev.screensnap.zoomIn")
    static let zoomOut = Notification.Name("com.georgebabichev.screensnap.zoomOut")
    static let resetZoom = Notification.Name("com.georgebabichev.screensnap.resetZoom")
}

class MenuState: ObservableObject {
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var hasSelectedImage = false
    
    static let shared = MenuState()
    private init() {}
}

@main
struct Screen_SnapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var menuState = MenuState.shared
    @AppStorage("hideDockIcon") private var hideDockIcon: Bool = false


    init() {
        GlobalHotKeyManager.shared.registerSnapHotKey()
        applyActivationPolicy(hideDockIcon)

    }

    var body: some Scene {
        // Remove WindowGroup entirely - we'll manage windows manually
        Settings {
            EmptyView()
        }
        .onChange(of: hideDockIcon) { _,newValue in
            applyActivationPolicy(newValue)
        }
        .commands {

            CommandGroup(after: .newItem) {
                Button {
                    WindowManager.shared.ensureMainWindow()
                    NotificationCenter.default.post(
                        name: .openImageFile,
                        object: nil
                    )
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Divider()
                
                Button {
                    NotificationCenter.default.post(name: .saveImage, object: nil)
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)
                
                Button {
                    NotificationCenter.default.post(name: .saveAsImage, object: nil)
                } label: {
                    Label("Save As…", systemImage: "square.and.arrow.down.on.square")
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!menuState.hasSelectedImage)
            }
            
            CommandGroup(replacing: .undoRedo) {
                Button {
                    NotificationCenter.default.post(name: .performUndo, object: nil)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!menuState.canUndo)
                
                Button {
                    NotificationCenter.default.post(name: .performRedo, object: nil)
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!menuState.canRedo)
            }
            
            CommandGroup(replacing: .pasteboard) {
                
                Button {
                    NotificationCenter.default.post(name: .copyToClipboard, object: nil)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

            }
            
            CommandMenu("Tools") {
                Button {
                    NotificationCenter.default.post(
                        name: .selectTool,
                        object: nil,
                        userInfo: ["tool": ToolKind.pointer.rawValue]
                    )
                } label: {
                    Label("Pointer", systemImage: "cursorarrow")
                }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

                Button {
                    NotificationCenter.default.post(
                        name: .selectTool,
                        object: nil,
                        userInfo: ["tool": ToolKind.pen.rawValue]
                    )
                } label: {
                    Label("Pen", systemImage: "pencil.line")
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

                Button {
                    NotificationCenter.default.post(
                        name: .selectTool,
                        object: nil,
                        userInfo: ["tool": ToolKind.arrow.rawValue]
                    )
                } label: {
                    Label("Arrow", systemImage: "arrow.right")
                }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

                Button {
                    NotificationCenter.default.post(
                        name: .selectTool,
                        object: nil,
                        userInfo: ["tool": ToolKind.highlighter.rawValue]
                    )
                } label: {
                    Label("Highlighter", systemImage: "highlighter")
                }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

                Button {
                    NotificationCenter.default.post(
                        name: .selectTool,
                        object: nil,
                        userInfo: ["tool": ToolKind.rect.rawValue]
                    )
                } label: {
                    Label("Rectangle", systemImage: "square.dashed")
                }
                .keyboardShortcut("5", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)
                
                Button {
                    NotificationCenter.default.post(
                        name: .selectTool,
                        object: nil,
                        userInfo: ["tool": ToolKind.oval.rawValue]
                    )
                } label: {
                    Label("Oval", systemImage: "circle.dashed")
                }
                .keyboardShortcut("6", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

                Button {
                    NotificationCenter.default.post(
                        name: .selectTool,
                        object: nil,
                        userInfo: ["tool": ToolKind.increment.rawValue]
                    )
                } label: {
                    Label("Badge", systemImage: "1.circle")
                }
                .keyboardShortcut("7", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

                Button {
                    NotificationCenter.default.post(
                        name: .selectTool,
                        object: nil,
                        userInfo: ["tool": ToolKind.text.rawValue]
                    )
                } label: {
                    Label("Text", systemImage: "textformat")
                }
                .keyboardShortcut("8", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

                Button {
                    NotificationCenter.default.post(
                        name: .selectTool,
                        object: nil,
                        userInfo: ["tool": ToolKind.crop.rawValue]
                    )
                } label: {
                    Label("Crop", systemImage: "crop")
                }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

            }
            
            CommandGroup(after: .sidebar) {
                Button {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                } label: { Text("Zoom In") }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

                Button {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                } label: { Text("Zoom Out") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)

                Button {
                    NotificationCenter.default.post(name: .resetZoom, object: nil)
                } label: { Text("Actual Size") }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!menuState.hasSelectedImage)
                
                Divider()
                
            }
        }
    }
}


private func applyActivationPolicy(_ hide: Bool) {
    // Must run on main thread for NSApp mutations.
    DispatchQueue.main.async {
        NSApp.setActivationPolicy(hide ? .accessory : .regular)

        // Optional: when re-showing the Dock icon, bring app forward so users see it.
        if !hide {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create initial window on app launch
        WindowManager.shared.ensureMainWindow()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app alive so the hotkey continues to work with no windows
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Defensive: ensure hotkey stays registered across weird state changes
        GlobalHotKeyManager.shared.registerSnapHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyManager.shared.unregister()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // No visible windows - create one
            WindowManager.shared.ensureMainWindow()
        }
        return true
    }
    
    // MARK: - File Opening Support
    
    /// Called when user opens files with the app (e.g., "Open With" context menu)
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleOpenFiles(filenames.map { URL(fileURLWithPath: $0) })
    }
    
    /// Called when files are opened via URL schemes or document types
    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenFiles(urls)
    }
    
    /// Handle opening image files in the app
    private func handleOpenFiles(_ urls: [URL]) {
        // Filter to only supported image formats
        let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "webp"]
        let imageURLs = urls.filter { url in
            guard url.isFileURL else { return false }
            let ext = url.pathExtension.lowercased()
            return supportedExtensions.contains(ext)
        }
        
        guard !imageURLs.isEmpty else {
            // No supported images found - show alert
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Unsupported File Type"
                alert.informativeText = "Screen Snap can only open image files (PNG, JPEG, HEIC, GIF, TIFF, WebP)."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }
        
        // Open the first supported image
        let firstImage = imageURLs[0]
        
        DispatchQueue.main.async {
            // Ensure we have a window and load the image
            WindowManager.shared.loadImageIntoWindow(url: firstImage, shouldActivate: true)
            
            // If multiple images were selected, you could show a picker or open them in separate windows
            if imageURLs.count > 1 {
                print("Multiple images selected. Currently opening the first one: \(firstImage.lastPathComponent)")
                // Optionally implement multi-image handling here
            }
        }
    }
    
}

// MARK: - Centralized Window Manager
final class WindowManager {
    static let shared = WindowManager()
    
    private var mainWindowController: NSWindowController?
    private let windowFrameAutosaveName = "MainEditorWindow"
    
    private init() {}
    
    /// Closes all app windows - used before screen capture
    func closeAllAppWindows() {
        // Close all visible windows belonging to our app
        for window in NSApp.windows {
            // Skip panels and sheets, focus on main windows
            if window.isVisible &&
               !window.isMiniaturized &&
               window.canBecomeKey &&
               !window.isSheet {
                
                window.close()
            }
        }
    }
    
    /// Ensures exactly one main window exists, creating if necessary
    func ensureMainWindow() {
        // If we already have a valid window, just bring it forward
        if let controller = mainWindowController,
           let window = controller.window,
           !window.isSheet {
            
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // Create new window
        createMainWindow()
    }
    
    /// Creates a window without activating the app
    private func ensureMainWindowWithoutActivating() {
        // If we already have a valid window, don't touch it at all
        if let controller = mainWindowController,
           let window = controller.window,
           !window.isSheet {
            
            // Don't even deminiaturize - just leave it as is
            return
        }
        
        // Create new window but don't activate
        createMainWindow(shouldActivate: false)
    }
    
    /// Creates a new main window, replacing any existing one
    private func createMainWindow(shouldActivate: Bool = true) {
        // Clean up existing window
        if let controller = mainWindowController {
            controller.window?.close()
            mainWindowController = nil
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 600)
        
        // Create ContentView
        let contentView = ContentView()
        window.contentViewController = NSHostingController(rootView: contentView)
        
        // Create and configure window controller
        let controller = NSWindowController(window: window)
        controller.windowFrameAutosaveName = windowFrameAutosaveName
        
        // Set up close notification to clean up our reference
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.mainWindowController = nil
        }
        
        // Store reference
        mainWindowController = controller
        
        // Show window differently based on activation requirement
        if shouldActivate {
            window.center()
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.center()
            // Just make window visible without making it key or activating the app
            window.orderFront(nil)
        }
    }
    /// Loads an image into the existing window, creating window if needed
    func loadImageIntoWindow(url: URL, shouldActivate: Bool = true) {
        if shouldActivate {
            ensureMainWindow()
        } else {
            ensureMainWindowWithoutActivating()
        }
        
        // Create a dictionary with both URL and activation flag
        let userInfo: [String: Any] = [
            "url": url,
            "shouldActivate": shouldActivate
        ]
        
        // Post notification with the dictionary
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: Notification.Name("com.georgebabichev.screensnap.beginSnapFromIntent"),
                object: nil,
                userInfo: userInfo
            )
        }
    }
    
    /// Check if we have a visible main window
    func hasVisibleWindow() -> Bool {
        guard let controller = mainWindowController,
              let window = controller.window else { return false }
        
        return window.isVisible && !window.isMiniaturized
    }
}

// MARK: - Global HotKey Manager (Updated with Window Closing)
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()
    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    
    private init() {}
    
    func registerSnapHotKey() {
        unregister()
        
        let keyCode: UInt32 = UInt32(kVK_ANSI_2)
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        
        let hotKeyID = EventHotKeyID(signature: OSType("SNAP".fourCC), id: UInt32(1))
        
        let handler: EventHandlerUPP = { _, eventRef, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            
            if hkID.signature == OSType("SNAP".fourCC), hkID.id == UInt32(1) {
                DispatchQueue.main.async {
                    GlobalHotKeyManager.shared.handleSnapHotkey()
                }
                return noErr
            }
            return noErr
        }
        
        let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        
        var eh: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, [eventType], nil, &eh)
        self.eventHandler = eh
        
        var hkRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         OptionBits(0),
                                         &hkRef)
        if status == noErr {
            self.hotKeyRef = hkRef
        }
    }
    
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
    }
    
    private func handleSnapHotkey() {
        // Close all app windows before starting selection
        WindowManager.shared.closeAllAppWindows()
        
        SelectionWindowManager.shared.present(onComplete: { rect in
            Task {
                if let img = await self.captureScreenshot(rect: rect) {
                    if let savedURL = ImageSaver.saveImage(img) {
                        DispatchQueue.main.async {
                            // Create a new window with the captured image
                            WindowManager.shared.loadImageIntoWindow(url: savedURL, shouldActivate: true)
                        }
                    }
                }
            }
        })
    }
    
    // Keep existing capture methods unchanged
    func captureScreenshot(rect selectedGlobalRect: CGRect) async -> NSImage? {
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
            let pxPerPtX = scale
            let pxPerPtY = scale
            
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            guard let fullCG = await ScreenCapturer.shared.captureImage(using: filter, display: scDisplay) else { return nil }
            
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
            let pointSize = CGSize(width: CGFloat(cropped.width) / pxPerPtX, height: CGFloat(cropped.height) / pxPerPtY)
            rep.size = pointSize
            
            let nsImage = NSImage(size: pointSize)
            nsImage.addRepresentation(rep)
            return nsImage
        } catch {
            return nil
        }
    }
    
    private func cropRectPixels(_ selectionPts: CGRect, withinScreenFramePts screenPts: CGRect, imageSizePx: CGSize, scaleX: CGFloat, scaleY: CGFloat) -> CGRect {
        let localXPts = selectionPts.origin.x - screenPts.origin.x
        let localYPts = selectionPts.origin.y - screenPts.origin.y
        let widthPx  = selectionPts.size.width * scaleX
        let heightPx = selectionPts.size.height * scaleY
        let xPx = localXPts * scaleX
        let yPx = imageSizePx.height - (localYPts * scaleY + heightPx)
        return CGRect(x: xPx.rounded(.down), y: yPx.rounded(.down), width: widthPx.rounded(.down), height: heightPx.rounded(.down))
    }
    
    private func bestScreenForSelection(_ selection: CGRect) -> NSScreen? {
        var best: (screen: NSScreen, area: CGFloat)?
        for s in NSScreen.screens {
            let a = selection.intersection(s.frame).area
            if a > (best?.area ?? 0) { best = (s, a) }
        }
        return best?.screen
    }
    
    
}

private extension String {
    var fourCC: UInt32 {
        var result: UInt32 = 0
        for char in utf16.prefix(4) {
            result = (result << 8) + UInt32(char)
        }
        return result
    }
}



private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
