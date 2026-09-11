
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
    case blur
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
    static let rotateClockwise = Notification.Name("com.georgebabichev.screenSnip.rotateClockwise")
    static let rotateCounterclockwise = Notification.Name("com.georgebabichev.screenSnip.rotateCounterclockwise")
    static let openNewWindow = Notification.Name("com.georgebabichev.screenSnip.openNewWindow") // Add this line
    static let requestCloseWindow = Notification.Name("com.georgebabichev.screenSnip.requestCloseWindow")
    static let requestTerminateApp = Notification.Name("com.georgebabichev.screenSnip.requestTerminateApp")

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
        UserDefaults.standard.register(defaults: [
            "preferredSaveFormat": SaveFormat.jpeg.rawValue,
            "downsampleToNonRetinaClipboard": false,
            "saveOnCopy": true,
            "captureMagnifierEnabled": true
        ])
        applyActivationPolicy(hideDockIcon)
    }

    var body: some Scene {
        Group {}
        .handlesExternalEvents(matching: Set(arrayLiteral: "never-match"))
        .onChange(of: hideDockIcon) { _,newValue in
            applyActivationPolicy(newValue)
        }
        .commands {
            AppCommands(menuState: menuState, appDelegate: appDelegate)
        }

        Settings {
            ScreenSnipSettingsView()
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

// MARK: - AppDelegate Changes (in Screen_SnipApp.swift)

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    
    // Add singleton access
    static var shared: AppDelegate!
    
    // Add these properties for permissions tracking
    @Published var needsScreenRecordingPermission = false
    @Published var showPermissionsView = false
    @Published var showAboutOverlay = false
    private var isAwaitingTerminationConfirmation = false
    
    override init() {
        super.init()
        AppDelegate.shared = self // Set the singleton reference
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let removedTemporaryFiles = TemporaryFileCleanup.removeLegacyAsyncImageDownloads()
        if removedTemporaryFiles > 0 {
            print("Cleaned up \(removedTemporaryFiles) legacy image-loading temporary files")
        }
        
        #if DEBUG
        print("Running in Debug mode")
        print("Debug app identity: bundle=\(Bundle.main.bundleIdentifier ?? "unknown") path=\(Bundle.main.bundleURL.path)")
        #else
        print("Running in Release mode")
        #endif

        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            print("App is sandboxed")
        } else {
            print("App is NOT sandboxed")
        }
        
        // Debug: show basic launch context
        let args = ProcessInfo.processInfo.arguments
        let env  = ProcessInfo.processInfo.environment
        if let flag = env["LAUNCHED_AT_LOGIN"] { print("🚀 Env[LAUNCHED_AT_LOGIN]=\(flag)") }

        // Check permissions first
        checkPermissions()

        GlobalHotKeyManager.shared.registerSnipHotKey()

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
            
            // AUTO-SHOW permissions if missing and not launched at login
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showPermissionsIfNeeded()
            }
        }
    }
    
    // NEW: Auto-show permissions when needed
    private func showPermissionsIfNeeded() {
        let hasScreenRecording = isScreenRecordingEnabled()
        
        if !hasScreenRecording && !showPermissionsView {
            print("⚠️ Auto-showing permissions view - Missing Screen Recording permission")
            showPermissionsView = true
        }
    }
    
    private func checkPermissions() {
        let hasScreenRecording = isScreenRecordingEnabled()
        
        needsScreenRecordingPermission = !hasScreenRecording
        
        if !hasScreenRecording {
            print("⚠️ Missing Screen Recording permission")
        }
    }
    
    // Add this method to refresh permission status
    func refreshPermissionStatus() {
        let hasScreenRecording = isScreenRecordingEnabled()
        
        needsScreenRecordingPermission = !hasScreenRecording
        
        if hasScreenRecording {
            showPermissionsView = false
        }
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
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let previousScreenRecording = !needsScreenRecordingPermission
        
        // Refresh permissions when app becomes active (user might have changed settings)
        refreshPermissionStatus()
        
        let nowHasScreenRecording = !needsScreenRecordingPermission
        
        if !previousScreenRecording && nowHasScreenRecording {
            showPermissionsView = false
        }
        
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if WindowManager.shared.isMainWindowDocumentEdited {
            guard !isAwaitingTerminationConfirmation else {
                return .terminateLater
            }
            isAwaitingTerminationConfirmation = true

            // The reply to a `.terminateLater` decision must happen after this
            // delegate method returns. A synchronous NotificationCenter post can
            // otherwise reply too early and leave AppKit waiting indefinitely.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .requestTerminateApp, object: nil)
            }
            return .terminateLater
        }

        prepareForTermination()
        return .terminateNow
    }

    func replyToPendingTermination(shouldTerminate: Bool) {
        guard isAwaitingTerminationConfirmation else { return }
        isAwaitingTerminationConfirmation = false

        if shouldTerminate {
            prepareForTermination()
        }

        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    private func prepareForTermination() {
        // Force close all sheets and modal windows immediately
        for window in NSApp.windows {
            // End any attached sheets
            if let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .cancel)
            }
            
            // Close any modal panels
            if window.isModalPanel {
                NSApp.stopModal(withCode: .cancel)
            }
        }
        
        // Force our SwiftUI sheet state to false
        DispatchQueue.main.async {
            self.showPermissionsView = false
        }
        
        // Stop any modal sessions
        NSApp.stopModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeyManager.shared.unregister()
        SnipDirectoryWatcher.shared.stop()
        SecurityScopedResourceManager.shared.releaseAll()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if GlobalHotKeyManager.shared.shouldSuppressMainWindowReopen {
            return false
        }
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
        print("🗂 handleOpenFiles called with \(urls.count) URLs:")
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
            
            let path = url.path
            
            // More specific filtering for launch arguments - only filter if it's clearly a launch artifact
            // Look for very specific patterns that indicate launch arguments, not just any container path
            if path.contains("/Library/Containers/") &&
               (path.hasSuffix("/YES") || path.hasSuffix("/NO")) &&
               !supportedExtensions.contains(url.pathExtension.lowercased()) {
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
            } else {
                print("  - ✅ Valid image file: \(url.lastPathComponent)")
            }
            return isSupported
        }
        
        guard !imageURLs.isEmpty else {
            print("⚠️ No valid image URLs found")
            return
        }
        
        let firstImage = imageURLs[0]
        print("📸 Opening image: \(firstImage.path)")
        
        DispatchQueue.main.async {
            // Ensure we have a main window first
            WindowManager.shared.ensureMainWindow()
            
            // Small delay to ensure window is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
                    print("📚 Multiple images selected. Currently opening the first one: \(firstImage.lastPathComponent)")
                }
            }
        }
    }
    
    // MARK: - About View
    @objc func showAboutWindow() {
        DispatchQueue.main.async {
            WindowManager.shared.ensureMainWindow()
            withAnimation(.easeInOut(duration: 0.2)) {
                self.showAboutOverlay = true
            }
        }
    }
}
