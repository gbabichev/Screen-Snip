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
    init() {
        GlobalHotKeyManager.shared.registerSnapHotKey()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - Global HotKey (⌘⇧2) using HIToolbox
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func registerSnapHotKey() {
        unregister() // safety if called twice

        // Unique HotKey ID: 'SNAP'/1
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E4150), id: UInt32(1))

        // Install handler to receive hotkey events
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let statusInstall = InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if hkID.signature == OSType(0x534E4150), hkID.id == 1 {
                // Reuse the same app-wide trigger your UI observes
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("com.xantrion.screensnap.beginSnapFromIntent"), object: nil)
                }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        guard statusInstall == noErr else {
            NSLog("InstallEventHandler failed: %d", statusInstall)
            return
        }

        // Register ⌘⇧2
        let keyCode = UInt32(kVK_ANSI_2)
        let modifiers = UInt32(cmdKey | shiftKey)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("RegisterEventHotKey failed: %d", status)
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
    }
}
