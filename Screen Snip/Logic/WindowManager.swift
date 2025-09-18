//
//  WindowManager.swift
//  Screen Snip
//
//  Created by George Babichev on 9/15/25.
//

import SwiftUI

// Window delegate to enforce minimum size constraints
class WindowSizeDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowSizeDelegate()
    private let minWidth: CGFloat = 1000
    private let minHeight: CGFloat = 600
    
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        return NSSize(
            width: max(frameSize.width, minWidth),
            height: max(frameSize.height, minHeight)
        )
    }
}

// Simplified window manager - let SwiftUI handle the window lifecycle
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    
    private var mainWindowController: NSWindowController?
    private let windowFrameAutosaveName = "MainEditorWindow"
    
    // Add UserDefaults keys for manual frame storage
    private let windowFrameKey = "MainEditorWindowFrame"
    private let defaultWindowSize = NSSize(width: 1000, height: 700)
    
    private init() {}
    
    func closeAllAppWindows() {
        // IMPORTANT: Save current window frame BEFORE closing to preserve good dimensions
        // (Don't wait for the close notification which might have collapsed dimensions)
        saveCurrentWindowFrame()
        
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
        
        // Get saved frame or use default
        let savedFrame = getSavedWindowFrame()
        
        let window = NSWindow(
            contentRect: savedFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        
        // Set up autosave name for built-in frame persistence
        window.setFrameAutosaveName(windowFrameAutosaveName)
        
        // Set minimum size to prevent too-small windows
        window.minSize = NSSize(width: 800, height: 500)
        
        // Also enforce minimum size via delegate to handle SwiftUI edge cases
        window.delegate = WindowSizeDelegate.shared
        // Don't set maxSize - let it be unlimited for resizing
        
        let contentView = ContentView()
        let hostingController = NSHostingController(rootView: contentView)
        
        // Don't set preferredContentSize - it interferes with resizing
        window.contentViewController = hostingController
        
        // Force the window to the exact saved frame immediately
        window.setFrame(savedFrame, display: false, animate: false)
        
        // Create and configure window controller
        let controller = NSWindowController(window: window)
        controller.windowFrameAutosaveName = windowFrameAutosaveName
        
        // Set up close notification to clean up our reference
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mainWindowController = nil
            }
        }
        
        // Also save frame when window is resized or moved (but throttled)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveCurrentWindowFrame()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveCurrentWindowFrame()
            }
        }
        
        // Store reference
        mainWindowController = controller
        
        if shouldActivate {
            // Don't center if we restored a saved frame
            if !hasSavedFrame() {
                window.center()
            }
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            if !hasSavedFrame() {
                window.center()
            }
            window.orderFront(nil)
        }
        
        // Final enforcement: ensure the frame is exactly what we want after everything settles
        DispatchQueue.main.async {
            if window.frame != savedFrame {
                window.setFrame(savedFrame, display: true, animate: false)
            }
        }
    }
    
    // MARK: - Frame Persistence
    
    private func getSavedWindowFrame() -> NSRect {
        // Try manual UserDefaults storage
        if let frameString = UserDefaults.standard.string(forKey: windowFrameKey) {
            let savedFrame = NSRectFromString(frameString)
            if isFrameValid(savedFrame) {
                return savedFrame
            }
        }
        
        // Final fallback - default size, centered
        let defaultFrame = NSRect(
            x: 100, y: 100,  // Will be centered anyway
            width: defaultWindowSize.width,
            height: defaultWindowSize.height
        )
        
        return defaultFrame
    }
    
    private var lastSaveTime: TimeInterval = 0
    private let saveThrottleInterval: TimeInterval = 0.1 // Only save once per 100ms
    
    private func saveCurrentWindowFrame() {
        guard let window = mainWindowController?.window else {
            return
        }
        
        let frame = window.frame
        
        // Don't save frames that are too small (probably minimized/collapsed)
        guard frame.width >= 300 && frame.height >= 200 else {
            return
        }
        
        // Throttle saves to prevent excessive UserDefaults writes
        let now = CACurrentMediaTime()
        guard now - lastSaveTime >= saveThrottleInterval else {
            return
        }
        lastSaveTime = now
                
        // Save to UserDefaults as backup
        let frameString = NSStringFromRect(frame)
        UserDefaults.standard.set(frameString, forKey: windowFrameKey)
        UserDefaults.standard.synchronize() // Force immediate save
        
        // The built-in autosave should handle this automatically, but we can force it
        window.saveFrame(usingName: windowFrameAutosaveName)
    }
    
    private func hasSavedFrame() -> Bool {
        // Check if we have saved frame data in UserDefaults
        if let frameString = UserDefaults.standard.string(forKey: windowFrameKey),
           !frameString.isEmpty {
            return true
        }
        
        return false
    }
    
    private func isFrameValid(_ frame: NSRect) -> Bool {
        
        // Check minimum size - be more lenient
        guard frame.width >= 400 && frame.height >= 300 else {
            return false
        }
        
        // Check if frame is at least partially on screen
        for screen in NSScreen.screens {
            if screen.frame.intersects(frame) {
                return true
            }
        }
        
        return false
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
    
    func closeAllAppWindowsAsync() async {
        await MainActor.run {
            self.closeAllAppWindows()
        }
        
        // Wait for window close animations to complete
        // Adjust timing based on your actual window close animation duration
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
    }
}
