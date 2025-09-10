//
//  Screen_SnapApp.swift
//  Screen Snap
//
//  Created by George Babichev on 9/8/25.
//

import SwiftUI
import Carbon.HIToolbox


@main
struct Screen_SnapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        GlobalHotKeyManager.shared.registerSnapHotKey()
    }

    var body: some Scene {
        WindowGroup("Screen Snap") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
}

// MARK: - Global HotKey (⌘⇧2) using HIToolbox
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// Register ⌘⇧2 as a true global hotkey (works even when app has no windows)
    func registerSnapHotKey() {
        unregister() // defensively clear any prior registration

        // Keycode for "2"
        let keyCode: UInt32 = UInt32(kVK_ANSI_2)
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)  // Carbon modifiers, not NSEvent flags

        var hotKeyID = EventHotKeyID(signature: OSType("SNAP".fourCC), id: UInt32(1))

        // Install a keyboard event handler (global scope)
        var handlerUPP: EventHandlerUPP? = nil
        let handler: EventHandlerUPP = { _, eventRef, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)

            // Match our "SNAP" hotkey
            if hkID.signature == OSType("SNAP".fourCC), hkID.id == UInt32(1) {
                // Do NOT activate the app here. Start capture first.
                DispatchQueue.main.async {
                    GlobalHotKeyManager.shared.handleSnapHotkey()
                }
                return noErr
            }
            return noErr
        }
        handlerUPP = handler

        let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // Attach to the application event target so it survives without a key window
        var eh: EventHandlerRef?
        InstallEventHandler(GetApplicationEventTarget(), handlerUPP, 1, [eventType], nil, &eh)
        self.eventHandler = eh

        // Register the hotkey
        var hkRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         OptionBits(0),
                                         &hkRef)
        if status == noErr {
            self.hotKeyRef = hkRef
        } else {
            NSLog("RegisterEventHotKey failed: %d", status)
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
    }

    /// Called when ⌘⇧2 is pressed
    private func handleSnapHotkey() {
        NSLog("[DEBUG] Global hotkey ⌘⇧2 received")
        // 1) Start selection/capture without activating the app UI.
        //    Put your existing selection-start function here.
        startScreenSelection { [weak self] imageURL in
            // 2) Once we have a snap, then show the editor and bring it forward.
            guard let url = imageURL else { return }
            self?.openEditor(with: url)
        }
    }

    // MARK: - Wire these to your existing app API

    private func startScreenSelection(completion: @escaping (URL?) -> Void) {
        NSLog("[DEBUG] GlobalHotKeyManager.startScreenSelection -> coordinator")
        SelectionCoordinator.shared.beginSelection(completion: completion)
    }

    private func openEditor(with url: URL) {
        // Recreate/show your editor window and make the app frontmost after capture
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .init("com.georgebabichev.screensnap.beginSnapFromIntent"),
                                        object: url)
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

// MARK: - SelectionCoordinator: persists even when no windows exist
final class SelectionCoordinator {
    static let shared = SelectionCoordinator()
    private var handler: (((URL?) -> Void) -> Void)?
    private init() {}

    /// ContentView (or any owner) calls this at launch/onAppear to provide the real selection entrypoint.
    func register(handler: @escaping (((URL?) -> Void) -> Void)) {
        NSLog("[DEBUG] SelectionCoordinator: registered selection handler")
        self.handler = handler
    }

    /// Begin selection. If a handler is registered, call it; otherwise fall back to the old notification.
    func beginSelection(completion: @escaping (URL?) -> Void) {
        if let handler = handler {
            NSLog("[DEBUG] SelectionCoordinator: invoking registered handler")
            handler(completion)
        } else {
            NSLog("[DEBUG] SelectionCoordinator: no handler; posting notification fallback")
            NotificationCenter.default.post(name: .init("StartSelectionFromHotkey"),
                                            object: completion)
        }
    }
}
