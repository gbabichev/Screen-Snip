//
//  AXPromptCoordinator.swift
//  Screen Snip
//
//  Created by George Babichev on 9/17/25.
//


import AppKit
import ApplicationServices

// Keep a strong reference to the anchor window so it can’t be deallocated mid-flight.
@MainActor
final class AXPromptCoordinator {
    static let shared = AXPromptCoordinator()
    private var anchorWindow: NSWindow?

    private func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else if let generic = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(generic)
        }
    }

    func requestAXPromptOnly() {
        // Ensure we're definitely on the main thread
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.requestAXPromptOnly()
            }
            return
        }

        // 1) Bring the app to the foreground so the system dialog is visible.
        NSApp.activate(ignoringOtherApps: true)

        // 2) Provide a stable presentation anchor if you might not have a key window.
        // Use a simple titled utility window (no nonactivating quirks).
        if NSApp.keyWindow == nil && NSApp.mainWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.titled, .utilityWindow],
                backing: .buffered, defer: false
            )
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.alphaValue = 0.01   // effectively invisible but present
            win.orderFrontRegardless()
            anchorWindow = win
        }

        // 3) Optional: benign AX read (“poke”) — harmless if untrusted.
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)

        // 4) Ask the system to prompt (CF types only).
        let opts: CFDictionary = [
            "AXTrustedCheckOptionPrompt" as CFString : kCFBooleanTrue
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        print("AX trusted immediately after call?:", trusted)
        if !trusted {
            // Close the anchor quickly to prevent stray UI, then open Settings
            if let win = anchorWindow { win.orderOut(nil); anchorWindow = nil }
            openAccessibilityPane()
        }

        // If still not trusted, open System Settings directly to the Accessibility pane.
        if !trusted {
            openAccessibilityPane()
        }

        // 5) Tear down the anchor a moment later (on main).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.anchorWindow?.orderOut(nil)
            self?.anchorWindow = nil
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.refreshPermissionStatus()
            }
        }
    }
}
