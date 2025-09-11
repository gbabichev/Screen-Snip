//
//  Screen_SnapApp.swift
//  Screen Snap
//
//  Created by George Babichev on 9/8/25.
//

import SwiftUI
import Carbon.HIToolbox
import ScreenCaptureKit

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
        
        // Check if there's already a window open
        for window in NSApp.windows {
            if let hosting = window.contentViewController as? NSHostingController<ContentView>,
               window.styleMask.contains(.titled),
               !window.isSheet {
                
                print("🔥 [DEBUG] Found existing window, using SelectionCoordinator")
                
                // Window exists, use the normal flow
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                
                SelectionCoordinator.shared.beginSelection { url in
                    // This completion won't be called since the existing window handles it
                }
                return
            }
        }
        
        print("🔥 [DEBUG] No window exists, starting selection FIRST, then creating window")
        
        // No window exists - start selection FIRST, then create window with the result
        SelectionWindowManager.shared.present(onComplete: { rect in
            Task {
                print("🔥 [DEBUG] Selection completed, now capturing...")
                if let img = await self.captureScreenshotForHotkey(rect: rect) {
                    print("🔥 [DEBUG] Capture successful, saving and creating window...")
                    if let savedURL = await self.saveImageToDiskForHotkey(img) {
                        print("🔥 [DEBUG] Saved to \(savedURL), creating editor window...")
                        DispatchQueue.main.async {
                            self.createWindowWithImage(url: savedURL, image: img)
                        }
                    }
                }
            }
        })
    }

    // Add these helper methods to GlobalHotKeyManager
    private func captureScreenshotForHotkey(rect selectedGlobalRect: CGRect) async -> NSImage? {
        // Use the same capture logic from ContentView
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
            
            let cropPx = cropRectPixelsForHotkey(intersectPts,
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

    private func cropRectPixelsForHotkey(_ selectionPts: CGRect, withinScreenFramePts screenPts: CGRect, imageSizePx: CGSize, scaleX: CGFloat, scaleY: CGFloat) -> CGRect {
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

    private func saveImageToDiskForHotkey(_ image: NSImage) async -> URL? {
        let fm = FileManager.default
        
        // Get save directory (same logic as ContentView)
        let saveDirectoryPath = UserDefaults.standard.string(forKey: "saveDirectoryPath") ?? ""
        let dir: URL
        if !saveDirectoryPath.isEmpty {
            dir = URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        } else {
            guard let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first else { return nil }
            dir = pictures.appendingPathComponent("Screen Snap", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let filename = "snap_\(formatter.string(from: Date())).png"
        let url = dir.appendingPathComponent(filename)
        
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func createWindowWithImage(url: URL, image: NSImage) {
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.tabbingMode = .disallowed
        newWindow.isReleasedWhenClosed = false
        newWindow.contentMinSize = NSSize(width: 900, height: 600)
        newWindow.title = "Screen Snap"
        
        // Use regular ContentView
        let contentView = ContentView()
        newWindow.contentViewController = NSHostingController(rootView: contentView)
        
        let windowController = NSWindowController(window: newWindow)
        windowController.windowFrameAutosaveName = "MainEditorWindow"
        
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        
        // Store reference to prevent deallocation
        WindowManager.shared.registerWindow(windowController)
        
        // Post notification to load the image after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            print("🔥 [DEBUG] Posting notification to load image: \(url)")
            NotificationCenter.default.post(
                name: Notification.Name("com.georgebabichev.screensnap.beginSnapFromIntent"),
                object: url
            )
        }
    }
    
    
    
    
    
    
    // MARK: - Wire these to your existing app API
    
    private func startScreenSelection(completion: @escaping (URL?) -> Void) {
        NSLog("[DEBUG] GlobalHotKeyManager.startScreenSelection -> coordinator")
        SelectionCoordinator.shared.beginSelection(completion: completion)
    }
    
    private func openEditor(with url: URL) {
        print("🔥 [DEBUG] openEditor called with URL: \(url)")
        
        // Recreate/show your editor window and make the app frontmost after capture
        NSApp.activate(ignoringOtherApps: true)
        
        // Try to find existing window first
        for window in NSApp.windows {
            print("🔥 [DEBUG] Checking window: \(window.title ?? "no title")")
            if let hosting = window.contentViewController as? NSHostingController<ContentView>,
               window.styleMask.contains(.titled),
               !window.isSheet {
                
                print("🔥 [DEBUG] Found existing ContentView window, posting notification")
                
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                
                // Post notification for existing window
                NotificationCenter.default.post(
                    name: Notification.Name("com.georgebabichev.screensnap.beginSnapFromIntent"),
                    object: url
                )
                return
            }
        }
        
        print("🔥 [DEBUG] No existing window found, creating new one")
        // No existing window - create new one and load the image directly
        if let img = NSImage(contentsOf: url) {
            print("🔥 [DEBUG] Successfully loaded image, creating window")
            createEditorWindow(with: url, image: img)
        } else {
            print("🔥 [DEBUG] ERROR: Failed to load image from URL")
        }
    }
    private func createEditorWindow(with url: URL, image: NSImage) {
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.tabbingMode = .disallowed
        newWindow.isReleasedWhenClosed = false
        newWindow.contentMinSize = NSSize(width: 900, height: 600)
        newWindow.title = "Screen Snap"
        
        // Create ContentView with preloaded image data
        let contentView = ContentViewWithPreload(url: url, image: image)
        newWindow.contentViewController = NSHostingController(rootView: contentView)
        
        let windowController = NSWindowController(window: newWindow)
        windowController.windowFrameAutosaveName = "MainEditorWindow"
        
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
        
        // Store reference to prevent deallocation
        WindowManager.shared.registerWindow(windowController)
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


private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
