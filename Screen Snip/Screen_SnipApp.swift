
import SwiftUI
import Combine
import os.log

// MARK: - App Group constants
private let kAppGroupID = "group.com.georgebabichev.Screen-Snip" // must match both targets' entitlements
private let kLaunchedByHelperKey = "launchedByHelper"



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
        // Remove Settings scene entirely - no Settings menu item
        // Use an empty WindowGroup that we'll never show - all windows handled by WindowManager
        
        Group {}
        .handlesExternalEvents(matching: Set(arrayLiteral: "never-match"))
        .onChange(of: hideDockIcon) { _,newValue in
            applyActivationPolicy(newValue)
        }
        .commands {
            AppCommands(menuState: menuState, appDelegate: appDelegate)
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
        // Debug: show basic launch context
        let args = ProcessInfo.processInfo.arguments
        let env  = ProcessInfo.processInfo.environment
        if let flag = env["LAUNCHED_AT_LOGIN"] { print("🚀 Env[LAUNCHED_AT_LOGIN]=\(flag)") }

        checkPermissions()

        if isAccessibilityEnabled() {
            GlobalHotKeyManager.shared.registerSnipHotKey()
        }

        // Primary and reliable signal: App Group flag set by the helper
        let defaults = UserDefaults(suiteName: kAppGroupID)
        let launchedViaAppGroup = defaults?.bool(forKey: kLaunchedByHelperKey) ?? false
        if launchedViaAppGroup {
            // consume the one-shot signal so subsequent manual launches behave normally
            defaults?.removeObject(forKey: kLaunchedByHelperKey)
        }

        // Secondary (dev) fallbacks in case you still launch with args/env from Xcode
        let launchedViaArg = args.contains("--launched-at-login")
        let launchedViaEnv = env["LAUNCHED_AT_LOGIN"] == "1"

        let launchedAtLogin = launchedViaAppGroup || launchedViaArg || launchedViaEnv

        if !launchedAtLogin {
            WindowManager.shared.ensureMainWindow()
        } 
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
        print("🔍 handleOpenFiles called with \(urls.count) URLs:")
        for (index, url) in urls.enumerated() {
            print("  [\(index)] \(url.absoluteString)")
            print("      - isFileURL: \(url.isFileURL)")
            print("      - path: \(url.path)")
            print("      - pathExtension: '\(url.pathExtension)'")
        }
        
        let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "webp"]
        let imageURLs = urls.filter { url in
            // First check if it's a file URL
            guard url.isFileURL else {
                print("  - Filtered out non-file URL: \(url.absoluteString)")
                return false
            }
            
            // Filter out paths that look like launch arguments or app container paths
            let path = url.path
            if path.contains("/Library/Containers/") && (path.hasSuffix("/YES") || path.hasSuffix("/NO")) {
                print("  - Filtered out launch argument artifact: \(path)")
                return false
            }
            
            // Check if the file actually exists
            guard FileManager.default.fileExists(atPath: path) else {
                print("  - Filtered out non-existent file: \(path)")
                return false
            }
            
            // Check if it has a supported extension
            let ext = url.pathExtension.lowercased()
            let isSupported = supportedExtensions.contains(ext)
            if !isSupported {
                print("  - Filtered out unsupported extension '\(ext)' for: \(url.lastPathComponent)")
            }
            return isSupported
        }
        
        guard !imageURLs.isEmpty else {
            print("⚠️ No valid image URLs found - not showing alert")
            return // Don't show alert for non-existent files or launch artifacts
        }
        
        let firstImage = imageURLs[0]
        
        DispatchQueue.main.async {
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





