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
import VideoToolbox

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
    private var capturedScreens: [(screenInfo: ScreenInfo, cgImage: CGImage)] = []
    
    // Sendable struct to hold screen data
    public struct ScreenInfo: Sendable {
        let frame: CGRect
        let backingScaleFactor: CGFloat
        let index: Int
    }
    
    private func handleSnipHotkey() {
        guard !isCurrentlyCapturing else { return }
        isCurrentlyCapturing = true
        
        print("Starting screen capture...")
        
        WindowManager.shared.closeAllAppWindows()
        
        // STEP 1: Capture all screens IMMEDIATELY
        Task { [weak self] in
            guard let self = self else { return }
            
            // Capture all screens right now, before showing selection UI
            let screenshots = await self.captureAllScreensImmediately()
            
            await MainActor.run {
                self.capturedScreens = screenshots
                
                // STEP 2: Show selection overlay displaying the captured static images
                SelectionWindowManager.shared.presentWithCapturedScreens(
                    capturedScreens: screenshots,
                    onComplete: { [weak self] rect in
                        // STEP 3: Extract selection from pre-captured screens
                        if let result = self?.extractSelectionFromCapturedScreens(rect: rect) {
                            if let savedURL = ImageSaver.saveImage(result) {
                                DispatchQueue.main.async {
                                    WindowManager.shared.loadImageIntoWindow(url: savedURL, shouldActivate: true)
                                }
                            }
                        }
                        
                        DispatchQueue.main.async { [weak self] in
                            self?.isCurrentlyCapturing = false
                            self?.capturedScreens.removeAll() // Clean up memory
                        }
                    }
                )
            }
        }
        
        SelectionWindowManager.shared.onCancel = { [weak self] in
            self?.isCurrentlyCapturing = false
            self?.capturedScreens.removeAll()
        }
    }
    
    // Extract selection from already-captured screens (synchronous since data is already in memory)
    private func extractSelectionFromCapturedScreens(rect selectedGlobalRect: CGRect) -> NSImage? {
        guard !capturedScreens.isEmpty else { return nil }
        
        guard let bestMatch = findBestScreenMatch(for: selectedGlobalRect, in: capturedScreens) else { return nil }
        
        return extractRegion(selectedGlobalRect, from: bestMatch)
    }
    
    // MARK: - Helper Functions
    
    private func captureAllScreensImmediately() async -> [(screenInfo: ScreenInfo, cgImage: CGImage)] {
        var results: [(screenInfo: ScreenInfo, cgImage: CGImage)] = []
        
        do {
            let content = try await SCShareableContent.current
            
            print("=== Multi-Monitor Capture Debug ===")
            print("Found \(content.displays.count) SCDisplays")
            print("Found \(NSScreen.screens.count) NSScreens")
            
            // Log all available displays
            for (index, display) in content.displays.enumerated() {
                print("SCDisplay \(index): ID=\(display.displayID), Size=\(display.width)x\(display.height)")
            }
            
            // Log all NSScreens
            for (index, screen) in NSScreen.screens.enumerated() {
                if let cgIDNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    let cgID = CGDirectDisplayID(truncating: cgIDNum)
                    print("NSScreen \(index): ID=\(cgID), Frame=\(screen.frame), Scale=\(screen.backingScaleFactor)")
                }
            }
            
            // Strategy 1: Try to match NSScreens to SCDisplays
            var matchedScreens: [(screenInfo: ScreenInfo, scDisplay: SCDisplay)] = []
            
            for (index, screen) in NSScreen.screens.enumerated() {
                if let cgIDNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    let cgID = CGDirectDisplayID(truncating: cgIDNum)
                    
                    if let scDisplay = content.displays.first(where: { $0.displayID == cgID }) {
                        let screenInfo = ScreenInfo(
                            frame: screen.frame,
                            backingScaleFactor: screen.backingScaleFactor,
                            index: index
                        )
                        matchedScreens.append((screenInfo: screenInfo, scDisplay: scDisplay))
                        print("✓ Matched NSScreen \(index) with SCDisplay ID \(cgID)")
                    } else {
                        print("✗ Could not match NSScreen \(index) (ID: \(cgID)) to any SCDisplay")
                    }
                } else {
                    print("✗ NSScreen \(index) has no NSScreenNumber")
                }
            }
            
            // Strategy 2: If matching failed, capture all SCDisplays and try to map them
            if matchedScreens.isEmpty && !content.displays.isEmpty {
                print("No matches found, falling back to capturing all SCDisplays")
                
                for (index, scDisplay) in content.displays.enumerated() {
                    // Try to find corresponding NSScreen by matching dimensions or position
                    let matchingNSScreen = NSScreen.screens.first { screen in
                        // Convert SCDisplay dimensions to points (accounting for potential scaling)
                        let scDisplayBounds = CGRect(x: 0, y: 0, width: scDisplay.width, height: scDisplay.height)
                        let screenBounds = screen.frame
                        
                        // Check if dimensions are close (allowing for scaling differences)
                        let widthRatio = Double(scDisplay.width) / screenBounds.width
                        let heightRatio = Double(scDisplay.height) / screenBounds.height
                        
                        return abs(widthRatio - heightRatio) < 0.1 // Allow for small scaling differences
                    }
                    
                    let screenInfo = ScreenInfo(
                        frame: matchingNSScreen?.frame ?? CGRect(x: 0, y: 0, width: scDisplay.width, height: scDisplay.height),
                        backingScaleFactor: matchingNSScreen?.backingScaleFactor ?? 1.0,
                        index: index
                    )
                    
                    matchedScreens.append((screenInfo: screenInfo, scDisplay: scDisplay))
                    print("Fallback: Added SCDisplay \(scDisplay.displayID) as screen \(index)")
                }
            }
            
            print("Proceeding with \(matchedScreens.count) screens to capture")
            
            // Capture screens sequentially instead of concurrently to avoid issues
            for (screenInfo, scDisplay) in matchedScreens {
                print("Capturing screen \(screenInfo.index) (SCDisplay ID: \(scDisplay.displayID))...")
                
                let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                
                // Create a fresh ScreenCapturer instance for each display
                let capturer = SingleDisplayCapturer()
                
                if let cgImage = await capturer.captureImage(using: filter, display: scDisplay) {
                    results.append((screenInfo: screenInfo, cgImage: cgImage))
                    print("✓ Successfully captured screen \(screenInfo.index): \(cgImage.width)x\(cgImage.height)")
                } else {
                    print("✗ Failed to capture screen \(screenInfo.index)")
                }
                
                // Small delay between captures to avoid overwhelming the system
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
            
        } catch {
            print("Failed to capture screens: \(error)")
        }
        
        print("Capture complete: \(results.count) screens captured successfully")
        return results
    }
    
    
    
    private func findBestScreenMatch(for selectedRect: CGRect, in screenshots: [(screenInfo: ScreenInfo, cgImage: CGImage)]) -> (screenInfo: ScreenInfo, cgImage: CGImage, intersection: CGRect)? {
        var bestMatch: (screenInfo: ScreenInfo, cgImage: CGImage, intersection: CGRect, area: CGFloat)?
        
        for (screenInfo, cgImage) in screenshots {
            let screenFrame = screenInfo.frame
            let intersection = selectedRect.intersection(screenFrame)
            
            if !intersection.isNull && !intersection.isEmpty {
                let area = intersection.width * intersection.height
                if area > (bestMatch?.area ?? 0) {
                    bestMatch = (screenInfo: screenInfo, cgImage: cgImage, intersection: intersection, area: area)
                }
            }
        }
        
        return bestMatch.map { (screenInfo: $0.screenInfo, cgImage: $0.cgImage, intersection: $0.intersection) }
    }
    
    private func extractRegion(_ selectedGlobalRect: CGRect, from match: (screenInfo: ScreenInfo, cgImage: CGImage, intersection: CGRect)) -> NSImage? {
        let (screenInfo, cgImage, intersectionRect) = match
        let screenFrame = screenInfo.frame
        let screenScale = screenInfo.backingScaleFactor
        
        // Get the app's scaling preference (only affects final output, not coordinate calculation)
        let downsampleToNonRetina = UserDefaults.standard.bool(forKey: "downsampleToNonRetinaForSave")
        
        print("=== Extract Region Debug ===")
        print("Selected global rect: \(selectedGlobalRect)")
        print("Screen frame: \(screenFrame)")
        print("Screen scale: \(screenScale)")
        print("Intersection rect: \(intersectionRect)")
        print("CGImage size: \(cgImage.width)x\(cgImage.height)")
        print("Downsample setting: \(downsampleToNonRetina)")
        
        // Convert from global coordinates to screen-local coordinates (in points)
        let localRect = CGRect(
            x: intersectionRect.origin.x - screenFrame.origin.x,
            y: intersectionRect.origin.y - screenFrame.origin.y,
            width: intersectionRect.width,
            height: intersectionRect.height
        )
        
        print("Local rect (points): \(localRect)")
        
        // Since we always capture at full resolution, always use the screen scale for pixel conversion
        let pixelScale = screenScale
        
        print("Pixel scale factor: \(pixelScale)")
        
        // Convert to pixel coordinates and flip Y axis (screen coordinates are bottom-left origin, CGImage is top-left)
        let pixelRect = CGRect(
            x: localRect.origin.x * pixelScale,
            y: CGFloat(cgImage.height) - (localRect.origin.y + localRect.height) * pixelScale,
            width: localRect.width * pixelScale,
            height: localRect.height * pixelScale
        ).integral
        
        print("Pixel rect (before clamping): \(pixelRect)")
        
        // Clamp to image bounds
        let clampedRect = CGRect(
            x: max(0, pixelRect.origin.x),
            y: max(0, pixelRect.origin.y),
            width: min(pixelRect.width, CGFloat(cgImage.width) - max(0, pixelRect.origin.x)),
            height: min(pixelRect.height, CGFloat(cgImage.height) - max(0, pixelRect.origin.y))
        )
        
        print("Clamped pixel rect: \(clampedRect)")
        
        guard clampedRect.width > 0 && clampedRect.height > 0,
              let croppedCGImage = cgImage.cropping(to: clampedRect) else {
            print("Failed to crop image - invalid rect or crop operation failed")
            return nil
        }
        
        print("Cropped image size: \(croppedCGImage.width)x\(croppedCGImage.height)")
        
        // Apply downsample setting here - affects final NSImage size only
        let finalPointSize: CGSize
        let finalCGImage: CGImage
        
        if downsampleToNonRetina {
            // Downsample to 1x resolution
            finalPointSize = CGSize(
                width: clampedRect.width / screenScale,
                height: clampedRect.height / screenScale
            )
            finalCGImage = croppedCGImage
            print("Downsampling to 1x: NSImage point size = \(finalPointSize)")
        } else {
            // Keep full resolution - NSImage point size equals pixel size
            finalPointSize = CGSize(width: clampedRect.width, height: clampedRect.height)
            finalCGImage = croppedCGImage
            print("Keeping full resolution: NSImage point size = \(finalPointSize)")
        }
        
        let rep = NSBitmapImageRep(cgImage: finalCGImage)
        rep.size = finalPointSize
        
        let nsImage = NSImage(size: finalPointSize)
        nsImage.addRepresentation(rep)
        
        return nsImage
    }
    
    
    
    
}



private final class SingleDisplayCapturer: NSObject, SCStreamOutput {
    private var captureResult: CGImage?
    private var captureError: Error?
    private var currentStream: SCStream?
    
    func captureImage(using filter: SCContentFilter, display: SCDisplay) async -> CGImage? {
        // Reset state
        captureResult = nil
        captureError = nil
        currentStream = nil
        
        do {
            // Find the matching NSScreen to get the backing scale factor
            let backingScale = getBackingScaleForDisplay(display) ?? 1.0
            let config = createFullResolutionConfig(for: display, backingScale: backingScale)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            currentStream = stream
            
            print("Stream config for display \(display.displayID):")
            print("  Display reported size: \(display.width)x\(display.height)")
            print("  Backing scale factor: \(backingScale)")
            print("  Configured capture size: \(config.width)x\(config.height)")
            
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            
            // Wait for result with timeout
            let startTime = CACurrentMediaTime()
            let timeout: TimeInterval = 5.0
            
            while captureResult == nil && captureError == nil {
                if CACurrentMediaTime() - startTime > timeout {
                    print("Capture timeout for display \(display.displayID)")
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            
            // Cleanup
            try stream.removeStreamOutput(self, type: .screen)
            try await stream.stopCapture()
            currentStream = nil
            
            if let error = captureError {
                print("Capture error for display \(display.displayID): \(error)")
                return nil
            }
            
            return captureResult
            
        } catch {
            print("Stream setup error for display \(display.displayID): \(error)")
            return nil
        }
    }
    
    private func createFullResolutionConfig(for display: SCDisplay, backingScale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        
        // Force native pixel resolution by scaling up the display dimensions
        config.width = Int(CGFloat(display.width) * backingScale)
        config.height = Int(CGFloat(display.height) * backingScale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        
        print("Full resolution config: \(config.width)x\(config.height) (scale factor: \(backingScale))")
        
        return config
    }
    
    private func getBackingScaleForDisplay(_ scDisplay: SCDisplay) -> CGFloat? {
        for screen in NSScreen.screens {
            if let cgIDNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let cgID = CGDirectDisplayID(truncating: cgIDNum)
                if cgID == scDisplay.displayID {
                    return screen.backingScaleFactor
                }
            }
        }
        return nil
    }
    
    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              captureResult == nil, // Only capture the first frame
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        
        if status == noErr, let cgImage = cgImage {
            captureResult = cgImage
        } else {
            captureError = NSError(domain: "CaptureError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage from pixel buffer"])
        }
    }
}
