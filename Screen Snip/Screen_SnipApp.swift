import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers
import Combine
import Cocoa

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
    static let selectTool = Notification.Name("com.georgebabichev.screenSnip.selectTool")
    static let openImageFile = Notification.Name("com.georgebabichev.screenSnip.openImageFile")
    static let copyToClipboard = Notification.Name("com.georgebabichev.screenSnip.copyToClipboard")
    static let performUndo = Notification.Name("com.georgebabichev.screenSnip.performUndo")
    static let performRedo = Notification.Name("com.georgebabichev.screenSnip.performRedo")
    static let saveImage = Notification.Name("com.georgebabichev.screenSnip.saveImage")
    static let saveAsImage = Notification.Name("com.georgebabichev.screenSnip.saveAsImage")
    static let zoomIn = Notification.Name("com.georgebabichev.screenSnip.zoomIn")
    static let zoomOut = Notification.Name("com.georgebabichev.screenSnip.zoomOut")
    static let resetZoom = Notification.Name("com.georgebabichev.screenSnip.resetZoom")
    static let openNewWindow = Notification.Name("com.georgebabichev.screenSnip.openNewWindow") // Add this line

}

class MenuState: ObservableObject {
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var hasSelectedImage = false
    
    static let shared = MenuState()
    private init() {}
}

@main
struct Screen_SnipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var menuState = MenuState.shared
    @AppStorage("hideDockIcon") private var hideDockIcon: Bool = false

    init() {
        // Initialize hotkey manager but don't register yet - do it in app delegate
        applyActivationPolicy(hideDockIcon)
    }

    var body: some Scene {
        
        Settings {
            EmptyView()
        }
        .onChange(of: hideDockIcon) { _,newValue in
            applyActivationPolicy(newValue)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button {
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
            
            CommandGroup(replacing: .help) {
                Button {
                    // Open help URL - replace with your actual help URL
                    if let url = URL(string: "https://github.com/gbabichev/Screen-Snip") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Help", systemImage: "questionmark.circle")
                }
                
                Button {
                    // Show privacy policy alert
                    let alert = NSAlert()
                    alert.messageText = "Privacy Policy"
                    alert.informativeText = "No data leaves your device ever - I don't touch it / know about it / care about it. It's yours."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                } label: {
                    Label("Privacy Policy", systemImage: "hand.raised.circle")
                }
            }
            
        }
    }
}

private func applyActivationPolicy(_ hide: Bool) {
    DispatchQueue.main.async {
        NSApp.setActivationPolicy(hide ? .accessory : .regular)
        if !hide {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        
        checkPermissions()
        
        // Register hotkey after app is fully launched (only if we have permissions)
        if isAccessibilityEnabled() {
            GlobalHotKeyManager.shared.registerSnipHotKey()
        }
        
        // Opens a window on launch.
        WindowManager.shared.ensureMainWindow()
    }
    
    private func checkPermissions() {
        let hasAccessibility = isAccessibilityEnabled()
        let hasScreenRecording = isScreenRecordingEnabled()
        
        if !hasAccessibility || !hasScreenRecording {
            DispatchQueue.main.async {
                self.showPermissionsAlert(
                    needsAccessibility: !hasAccessibility,
                    needsScreenRecording: !hasScreenRecording
                )
            }
        }
    }
    
    private func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }
    
    private func isScreenRecordingEnabled() -> Bool {
        // Check if we can capture screen content
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        } else {
            // For older macOS versions, we can't easily check this
            // Return true and let the user discover when they try to use it
            return true
        }
    }
    
    private func showPermissionsAlert(needsAccessibility: Bool, needsScreenRecording: Bool) {
        let alert = NSAlert()
        
        var missingPermissions: [String] = []
        if needsAccessibility {
            missingPermissions.append("Accessibility")
        }
        if needsScreenRecording {
            missingPermissions.append("Screen Recording")
        }
        
        let permissionList = missingPermissions.joined(separator: " and ")
        
        alert.messageText = "\(permissionList) Permission\(missingPermissions.count > 1 ? "s" : "") Required"
        
        var informativeText = "Screen Snip needs the following permissions to work properly:\n\n"
        
        if needsAccessibility {
            informativeText += "• Accessibility: Required to capture screenshots with the global hotkey (⌘⇧2)\n"
        }
        
        if needsScreenRecording {
            informativeText += "• Screen Recording: Required to capture screen content\n"
        }
        
        informativeText += "\nPlease grant these permissions in System Preferences > Privacy & Security."
        
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Continue with Limited Features")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            openPrivacyPreferences(needsAccessibility: needsAccessibility, needsScreenRecording: needsScreenRecording)
            
            // Show a follow-up dialog
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.showPermissionFollowUpAlert(
                    needsAccessibility: needsAccessibility,
                    needsScreenRecording: needsScreenRecording
                )
            }
        }
    }
    
    private func openPrivacyPreferences(needsAccessibility: Bool, needsScreenRecording: Bool) {
        // Try to open the most relevant preference pane
        var urlString: String
        
        if needsAccessibility && needsScreenRecording {
            // If both are needed, open the main Privacy & Security pane
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        } else if needsAccessibility {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func showPermissionFollowUpAlert(needsAccessibility: Bool, needsScreenRecording: Bool) {
        let alert = NSAlert()
        alert.messageText = "Grant Permissions and Restart"
        
        var instructionText = "After enabling the required permissions for Screen Snip:\n\n"
        
        if needsAccessibility {
            instructionText += "1. Go to Privacy & Security > Accessibility\n"
            instructionText += "2. Enable Screen Snip in the list\n"
        }
        
        if needsScreenRecording {
            if needsAccessibility {
                instructionText += "3. Go to Privacy & Security > Screen Recording\n"
                instructionText += "4. Enable Screen Snip in the list\n"
                instructionText += "\n5. Restart Screen Snip for all features to work properly."
            } else {
                instructionText += "1. Go to Privacy & Security > Screen Recording\n"
                instructionText += "2. Enable Screen Snip in the list\n"
                instructionText += "\n3. Restart Screen Snip for all features to work properly."
            }
        } else {
            instructionText += "\n3. Restart Screen Snip for the hotkey to work properly."
        }
        
        alert.informativeText = instructionText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    // Keep your existing methods below
    private func showAccessibilityPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Screen Snip needs accessibility permissions to capture screenshots with the global hotkey (⌘⇧2). Please grant permission in System Preferences > Privacy & Security > Accessibility."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Continue Without Hotkey")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // Open System Preferences to Privacy & Security > Accessibility
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            
            // Show a follow-up dialog
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.showPermissionFollowUpAlert()
            }
        }
    }
    
    private func showPermissionFollowUpAlert() {
        let followUpAlert = NSAlert()
        followUpAlert.messageText = "Grant Permission and Restart"
        followUpAlert.informativeText = "After enabling accessibility permissions for Screen Snip, please restart the app for the hotkey to work."
        followUpAlert.alertStyle = .informational
        followUpAlert.addButton(withTitle: "OK")
        followUpAlert.runModal()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        GlobalHotKeyManager.shared.registerSnipHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyManager.shared.unregister()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowManager.shared.ensureMainWindow()
        }
        return true
    }
    
    // MARK: - File Opening Support
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleOpenFiles(filenames.map { URL(fileURLWithPath: $0) })
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenFiles(urls)
    }
    
    private func handleOpenFiles(_ urls: [URL]) {
        let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "webp"]
        let imageURLs = urls.filter { url in
            guard url.isFileURL else { return false }
            let ext = url.pathExtension.lowercased()
            return supportedExtensions.contains(ext)
        }
        
        guard !imageURLs.isEmpty else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Unsupported File Type"
                alert.informativeText = "Screen Snip can only open image files (PNG, JPEG, HEIC, GIF, TIFF, WebP)."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return
        }
        
        let firstImage = imageURLs[0]
        
        DispatchQueue.main.async {
            // Send notification to load the image
            let userInfo: [String: Any] = [
                "url": firstImage,
                "shouldActivate": true
            ]
            
            NotificationCenter.default.post(
                name: Notification.Name("com.georgebabichev.screenSnip.beginSnipFromIntent"),
                object: nil,
                userInfo: userInfo
            )
            
            if imageURLs.count > 1 {
                print("Multiple images selected. Currently opening the first one: \(firstImage.lastPathComponent)")
            }
        }
    }
}


// Simplified window manager - let SwiftUI handle the window lifecycle
final class WindowManager {
    static let shared = WindowManager()
    
    private var mainWindowController: NSWindowController?
    private let windowFrameAutosaveName = "MainEditorWindow"
    
    private init() {}
    
    func closeAllAppWindows() {
        for window in NSApp.windows {
            if window.isVisible &&
               !window.isMiniaturized &&
               window.canBecomeKey &&
               !window.isSheet {
                
                window.close()
            }
        }
    }
    
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
        
        if shouldActivate {
            window.center()
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.center()
            window.orderFront(nil)
        }
    }
    
    func loadImageIntoWindow(url: URL, shouldActivate: Bool = true) {
        // Always ensure we have a window first
        ensureMainWindow()
        
        let userInfo: [String: Any] = [
            "url": url,
            "shouldActivate": shouldActivate
        ]
        
        // Send notification immediately - now there's a ContentView to receive it
        NotificationCenter.default.post(
            name: Notification.Name("com.georgebabichev.screenSnip.beginSnipFromIntent"),
            object: nil,
            userInfo: userInfo
        )
    }
    
    func hasVisibleWindow() -> Bool {
        guard let controller = mainWindowController,
              let window = controller.window else { return false }
        
        return window.isVisible && !window.isMiniaturized
    }
}


final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private init() {}
    
    func registerSnipHotKey() {
        unregister()
        
        guard AXIsProcessTrusted() else {
            print("Accessibility permissions not granted. Cannot register hotkey.")
            return
        }
        
        // Request accessibility permissions if needed
        guard AXIsProcessTrusted() else {
            print("Accessibility permissions not granted. Cannot register hotkey.")
            return
        }
        
        // Create event tap for system-wide key monitoring
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                
                if manager.handleCGEvent(event) {
                    // Consume the event
                    return nil
                } else {
                    // Pass the event through
                    return Unmanaged.passUnretained(event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            print("Failed to create event tap")
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("Registered system-wide hotkey monitor")
    }
    
    func unregister() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            
            if let runLoopSource = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                self.runLoopSource = nil
            }
            
            self.eventTap = nil
            print("Unregistered hotkey monitor")
        }
    }
    
    private func handleCGEvent(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        
        // Check for Cmd+Shift+2
        guard keyCode == 19,  // Key code for '2'
              flags.contains(.maskCommand),
              flags.contains(.maskShift) else {
            return false // Don't consume the event
        }
        
        guard !isCurrentlyCapturing else { return true }
        
        print("System-wide hotkey detected: Cmd+Shift+2")
        
        DispatchQueue.main.async { [weak self] in
            self?.handleSnipHotkey()
        }
        
        return true // Consume the event
    }
    
    private var isCurrentlyCapturing = false
    
    private func handleSnipHotkey() {
        guard !isCurrentlyCapturing else { return }
        isCurrentlyCapturing = true
        
        print("Starting screen capture...")
        
        WindowManager.shared.closeAllAppWindows()
        
        SelectionWindowManager.shared.present(onComplete: { [weak self] rect in
            Task { [weak self] in
                defer {
                    DispatchQueue.main.async { [weak self] in
                        self?.isCurrentlyCapturing = false
                    }
                }
                
                if let img = await self?.captureScreenshot(rect: rect) {
                    if let savedURL = ImageSaver.saveImage(img) {
                        DispatchQueue.main.async {
                            WindowManager.shared.loadImageIntoWindow(url: savedURL, shouldActivate: true)
                        }
                    }
                }
            }
        })
        
        SelectionWindowManager.shared.onCancel = { [weak self] in
            self?.isCurrentlyCapturing = false
        }
    }
    
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

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
