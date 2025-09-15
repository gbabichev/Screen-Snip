import SwiftUI
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
            
            CommandGroup(replacing: .appInfo) {
                Button {
                    appDelegate.showAboutWindow()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            }
            
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
    
    // MARK: - About View
    @objc func showAboutWindow() {
        let aboutView = AboutView() // Your SwiftUI view
        let hostingController = NSHostingController(rootView: aboutView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "About"
        window.setContentSize(NSSize(width: 400, height: 400))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        NSApp.activate(ignoringOtherApps: true)
    }
    
}





