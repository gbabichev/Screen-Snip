//
//  WindowManager.swift
//  Screen Snip
//
//  Created by George Babichev on 9/15/25.
//

import SwiftUI

// Simplified window manager - let SwiftUI handle the window lifecycle
@MainActor
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
            Task { @MainActor in
                self?.mainWindowController = nil
            }
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
}

