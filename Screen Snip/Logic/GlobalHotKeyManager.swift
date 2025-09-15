//
//  GlobalHotKeyManager.swift
//  Screen Snip
//
//  Created by George Babichev on 9/15/25.
//

import SwiftUI
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import Combine
import Cocoa

final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private init() {}
    
    func registerSnipHotKey() {
        unregister()
        
        guard AXIsProcessTrusted() else {
            print("Accessibility permissions not granted. Cannot register hotkey.")
            return
        }
        
        // Request accessibility permissions if needed
        guard AXIsProcessTrusted() else {
            print("Accessibility permissions not granted. Cannot register hotkey.")
            return
        }
        
        // Create event tap for system-wide key monitoring
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                
                if manager.handleCGEvent(event) {
                    // Consume the event
                    return nil
                } else {
                    // Pass the event through
                    return Unmanaged.passUnretained(event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            print("Failed to create event tap")
            return
        }
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        
        print("Registered system-wide hotkey monitor")
    }
    
    func unregister() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            
            if let runLoopSource = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
                self.runLoopSource = nil
            }
            
            self.eventTap = nil
            print("Unregistered hotkey monitor")
        }
    }
    
    private func handleCGEvent(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        
        // Check for Cmd+Shift+2
        guard keyCode == 19,  // Key code for '2'
              flags.contains(.maskCommand),
              flags.contains(.maskShift) else {
            return false // Don't consume the event
        }
        
        guard !isCurrentlyCapturing else { return true }
        
        print("System-wide hotkey detected: Cmd+Shift+2")
        
        DispatchQueue.main.async { [weak self] in
            self?.handleSnipHotkey()
        }
        
        return true // Consume the event
    }
    
    private var isCurrentlyCapturing = false
    
    private func handleSnipHotkey() {
        guard !isCurrentlyCapturing else { return }
        isCurrentlyCapturing = true
        
        print("Starting screen capture...")
        
        WindowManager.shared.closeAllAppWindows()
        
        SelectionWindowManager.shared.present(onComplete: { [weak self] rect in
            Task { [weak self] in
                defer {
                    DispatchQueue.main.async { [weak self] in
                        self?.isCurrentlyCapturing = false
                    }
                }
                
                if let img = await self?.captureScreenshot(rect: rect) {
                    if let savedURL = ImageSaver.saveImage(img) {
                        DispatchQueue.main.async {
                            WindowManager.shared.loadImageIntoWindow(url: savedURL, shouldActivate: true)
                        }
                    }
                }
            }
        })
        
        SelectionWindowManager.shared.onCancel = { [weak self] in
            self?.isCurrentlyCapturing = false
        }
    }
    
    func captureScreenshot(rect selectedGlobalRect: CGRect) async -> NSImage? {
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
            
            let cropPx = cropRectPixels(intersectPts,
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
    
    private func cropRectPixels(_ selectionPts: CGRect, withinScreenFramePts screenPts: CGRect, imageSizePx: CGSize, scaleX: CGFloat, scaleY: CGFloat) -> CGRect {
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
            let a = max(0, selection.intersection(s.frame).width) * max(0, selection.intersection(s.frame).height)
            if a > (best?.area ?? 0) { best = (s, a) }
        }
        return best?.screen
    }
}
