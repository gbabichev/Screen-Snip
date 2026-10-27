//
//  WindowManager.swift
//  Screen Snip
//
//  Created by George Babichev on 9/15/25.
//

import SwiftUI

final class WindowCloseCoordinator {
    static let shared = WindowCloseCoordinator()
    var allowClose = false
    private init() {}
}

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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if WindowCloseCoordinator.shared.allowClose {
            WindowCloseCoordinator.shared.allowClose = false
            return true
        }
        NotificationCenter.default.post(name: .requestCloseWindow, object: sender)
        return false
    }
}

// Retains editor windows and their view state across captures.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    
    private var mainWindowController: NSWindowController?
    private var editors: [UUID: NSWindowController] = [:]
    private var editorObservers: [UUID: [NSObjectProtocol]] = [:]
    private var terminationEditors: [UUID] = []

    private struct CaptureWindowState {
        let windows: [NSWindow]
        let keyWindow: NSWindow?
        let frontmostApplication: NSRunningApplication?
        let appWasActive: Bool
        let appWasHidden: Bool
    }
    private var captureWindowState: CaptureWindowState?
    private let windowFrameAutosaveName = "MainEditorWindow"
    
    // Add UserDefaults keys for manual frame storage
    private let windowFrameKey = "MainEditorWindowFrame"
    private let defaultWindowSize = NSSize(width: 1000, height: 700)
    
    private init() {}
    
    func beginCapture(hideWindows: Bool) {
        guard captureWindowState == nil else { return }
        saveCurrentWindowFrame()
        let visibleWindows = NSApp.orderedWindows.filter { $0.isVisible && !$0.isMiniaturized && !$0.isSheet }
        captureWindowState = CaptureWindowState(
            windows: hideWindows ? visibleWindows : [],
            keyWindow: NSApp.keyWindow,
            frontmostApplication: NSWorkspace.shared.frontmostApplication,
            appWasActive: NSApp.isActive,
            appWasHidden: NSApp.isHidden
        )
        if hideWindows {
            for window in visibleWindows { window.orderOut(nil) }
        }
    }

    func finishCapture(restoreFocus: Bool) {
        guard let state = captureWindowState else { return }
        captureWindowState = nil
        // orderBack preserves the order within the app without raising it over
        // the app the person was using before the capture.
        for window in state.windows where !window.isVisible && !window.isMiniaturized {
            window.orderBack(nil)
        }
        guard restoreFocus else { return }
        if state.appWasHidden {
            NSApp.hide(nil)
        } else if state.appWasActive {
            state.keyWindow?.makeKeyAndOrderFront(nil)
        }
        if !state.appWasActive {
            state.frontmostApplication?.activate(options: [])
        }
    }

    func window(for editorID: UUID) -> NSWindow? { editors[editorID]?.window }

    func isActiveEditor(_ editorID: UUID) -> Bool {
        guard let window = window(for: editorID) else { return false }
        return NSApp.keyWindow === window
    }

    func setDocumentEdited(_ edited: Bool, for editorID: UUID) {
        window(for: editorID)?.isDocumentEdited = edited
    }

    var hasEditedEditors: Bool { editors.values.contains { $0.window?.isDocumentEdited == true } }

    func beginTerminationConfirmation() {
        terminationEditors = editors.compactMap { $0.value.window?.isDocumentEdited == true ? $0.key : nil }
    }

    @discardableResult func confirmNextEditorBeforeTermination() -> Bool {
        while !terminationEditors.isEmpty {
            let id = terminationEditors.removeFirst()
            guard let window = window(for: id), window.isDocumentEdited else { continue }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .requestTerminateApp, object: window)
            }
            return true
        }
        return false
    }

    func cancelTerminationConfirmation() { terminationEditors.removeAll() }

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

    private func removeEditor(_ id: UUID) {
        guard let controller = editors.removeValue(forKey: id) else { return }
        for observer in editorObservers.removeValue(forKey: id) ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
        if mainWindowController === controller {
            mainWindowController = editors.values.first
        }
        withExtendedLifetime(controller) {}
    }

    private func createMainWindow(shouldActivate: Bool = true) {
        // Keep existing editors alive, including their unsaved view state.
        let editorID = UUID()
        
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
        
        let contentView = ContentView(editorID: editorID)
#if DEBUG
            .overlay(alignment: .bottomTrailing) {
                BetaTag()
                    .padding(12)
            }
#endif
        let hostingController = NSHostingController(rootView: contentView)
        
        // Don't set preferredContentSize - it interferes with resizing
        window.contentViewController = hostingController
        
        // Force the window to the exact saved frame immediately
        window.setFrame(savedFrame, display: false, animate: false)
        
        // Create and configure window controller
        let controller = NSWindowController(window: window)
        controller.windowFrameAutosaveName = windowFrameAutosaveName
        
        // Retain every editor and scope lifecycle observations to it.
        editors[editorID] = controller
        var observers: [NSObjectProtocol] = []
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.removeEditor(editorID)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor in
                guard let self, window?.isKeyWindow == true,
                      let controller = self.editors[editorID] else { return }
                self.mainWindowController = controller
            }
        })
        
        // Also save frame when window is resized or moved (but throttled)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveCurrentWindowFrame()
            }
        })
        
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.saveCurrentWindowFrame()
            }
        })
        
        editorObservers[editorID] = observers
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
        if mainWindowController?.window?.isDocumentEdited == true ||
            mainWindowController?.window?.isMiniaturized == true {
            createMainWindow(shouldActivate: shouldActivate)
        } else {
            ensureMainWindow()
        }
        let targetWindow = mainWindowController?.window
        
        let userInfo: [String: Any] = [
            "url": url,
            "shouldActivate": shouldActivate
        ]
        
        // Allow a newly created hosting view to install its subscriptions.
        DispatchQueue.main.async { [weak targetWindow] in
            guard let targetWindow else { return }
            NotificationCenter.default.post(
                name: Notification.Name("com.georgebabichev.screenSnip.beginSnipFromIntent"),
                object: targetWindow,
                userInfo: userInfo
            )
        }
    }
}
