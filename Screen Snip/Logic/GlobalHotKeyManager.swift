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

final class GlobalHotKeyManager: NSObject, SCContentSharingPickerObserver {
    static let shared = GlobalHotKeyManager()
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private var isWindowPickerConfigured = false

    private override init() {
        super.init()
    }
    
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
                
                if manager.handleCGEvent(type: type, event: event) {
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
    
    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                print("Re-enabled system-wide hotkey monitor after macOS disabled it")
            }
            return false
        }

        guard type == .keyDown else { return false }

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
    private var suppressMainWindowReopenUntil: CFTimeInterval = 0
    private var shouldRestoreMainWindowAfterCapture = false

    var shouldSuppressMainWindowReopen: Bool {
        isCurrentlyCapturing ||
        SelectionWindowManager.shared.isPresentingSelection ||
        CACurrentMediaTime() < suppressMainWindowReopenUntil
    }

    private func suppressMainWindowReopenBriefly() {
        suppressMainWindowReopenUntil = CACurrentMediaTime() + 1.0
    }
    
    // Sendable struct to hold screen data
    struct ScreenInfo: Sendable {
        let frame: CGRect
        let backingScaleFactor: CGFloat
        let index: Int
    }
    
    private func handleSnipHotkey() {
        guard !isCurrentlyCapturing else { return }
        isCurrentlyCapturing = true

        let captureTypeRaw = UserDefaults.standard.string(forKey: "captureType")
            ?? CaptureType.dragToSelect.rawValue
        let captureType = CaptureType(rawValue: captureTypeRaw) ?? .dragToSelect

        switch captureType {
        case .dragToSelect:
            beginDragSelectionCapture()
        case .fullWindow:
            shouldRestoreMainWindowAfterCapture = false
            presentSystemWindowPicker()
        }
    }

    private func beginDragSelectionCapture() {
        let captureModeRaw = UserDefaults.standard.string(forKey: "captureMode")
            ?? CaptureMode.captureWithWindows.rawValue
        let captureMode = CaptureMode(rawValue: captureModeRaw) ?? .captureWithWindows
        let windowsWereHidden = captureMode == .captureWithoutWindows

        let hadVisibleMainWindow = NSApp.windows.contains { window in
            window.isVisible &&
            !window.isMiniaturized &&
            window.canBecomeKey &&
            !window.isSheet &&
            window.contentViewController is NSHostingController<ContentView>
        }
        shouldRestoreMainWindowAfterCapture = windowsWereHidden && hadVisibleMainWindow

        SelectionWindowManager.shared.onCancel = { [weak self] in
            self?.finishCapture(restorePreviousMainWindow: true)
        }

        switch captureMode {
        case .captureWithWindows:
            handleCaptureWithWindows()
        case .captureWithoutWindows:
            handleCaptureWithoutWindows()
        }
    }

    private func presentSystemWindowPicker() {
        let picker = SCContentSharingPicker.shared

        if !isWindowPickerConfigured {
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = .singleWindow
            configuration.allowsChangingSelectedContent = false
            if let bundleIdentifier = Bundle.main.bundleIdentifier {
                configuration.excludedBundleIDs = [bundleIdentifier]
            }

            picker.defaultConfiguration = configuration
            picker.maximumStreamCount = 1
            picker.add(self)
            isWindowPickerConfigured = true
        }

        picker.isActive = true
        NSApp.activate(ignoringOtherApps: true)
        picker.present(using: .window)
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        DispatchQueue.main.async { [weak self] in
            picker.isActive = false
            self?.finishCapture(restorePreviousMainWindow: true)
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.captureSelectedWindow(using: filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            print("Window picker failed to open: \(error)")
            NSSound.beep()
            SCContentSharingPicker.shared.isActive = false
            self?.finishCapture(restorePreviousMainWindow: true)
        }
    }

    private func captureSelectedWindow(using filter: SCContentFilter) {
        Task { [weak self] in
            do {
                let configuration = SCScreenshotConfiguration()
                configuration.showsCursor = false
                configuration.ignoreShadows = false
                configuration.ignoreClipping = false
                configuration.dynamicRange = .sdr

                let output = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: filter,
                    configuration: configuration
                )

                guard let cgImage = output.sdrImage else {
                    throw WindowCaptureError.missingImage
                }

                let pointScale = max(CGFloat(filter.pointPixelScale), 1)
                let pointSize = CGSize(
                    width: CGFloat(cgImage.width) / pointScale,
                    height: CGFloat(cgImage.height) / pointScale
                )
                let representation = NSBitmapImageRep(cgImage: cgImage)
                representation.size = pointSize
                let image = NSImage(size: pointSize)
                image.addRepresentation(representation)

                await MainActor.run {
                    var didSaveCapture = false
                    if let savedURL = ImageSaver.saveImage(image) {
                        didSaveCapture = true
                        WindowManager.shared.loadImageIntoWindow(url: savedURL, shouldActivate: true)
                    } else {
                        print("Window capture could not be saved")
                        NSSound.beep()
                    }

                    SCContentSharingPicker.shared.isActive = false
                    self?.finishCapture(restorePreviousMainWindow: !didSaveCapture)
                }
            } catch {
                await MainActor.run {
                    print("Failed to capture selected window: \(error)")
                    NSSound.beep()
                    SCContentSharingPicker.shared.isActive = false
                    self?.finishCapture(restorePreviousMainWindow: true)
                }
            }
        }
    }

    private enum WindowCaptureError: Error {
        case missingImage
    }

    private func finishCapture(restorePreviousMainWindow: Bool) {
        let shouldRestore = restorePreviousMainWindow && shouldRestoreMainWindowAfterCapture

        suppressMainWindowReopenBriefly()
        isCurrentlyCapturing = false
        capturedScreens.removeAll()
        shouldRestoreMainWindowAfterCapture = false
        SelectionWindowManager.shared.onCancel = nil

        if shouldRestore {
            DispatchQueue.main.async {
                WindowManager.shared.ensureMainWindow()
            }
        }
    }

    // MARK: - Capture Mode Implementations

    // Option 3: Capture with windows visible (what user sees)
    private func handleCaptureWithWindows() {
        Task { [weak self] in
            guard let self = self else { return }
            
            // STEP 1: Capture all screens with windows visible
            let screenshots = await self.captureAllScreensImmediately()
            
            await MainActor.run {
                // STEP 2: Show selection overlay directly - NO window manipulation
                self.capturedScreens = screenshots
                self.presentSelectionUI(with: screenshots)
            }
        }
    }

    // Option 2: Capture without windows (clean desktop)
    private func handleCaptureWithoutWindows() {
        Task { [weak self] in
            guard let self = self else { return }
            
            // STEP 1: Hide windows first for clean desktop
            await WindowManager.shared.closeAllAppWindowsAsync()
            
            // STEP 2: Capture with windows hidden
            let screenshots = await self.captureAllScreensImmediately()
            
            await MainActor.run {
                self.capturedScreens = screenshots
                self.presentSelectionUI(with: screenshots)
            }
        }
    }

    // MARK: - Shared Selection UI Logic

    private func presentSelectionUI(with screenshots: [(screenInfo: ScreenInfo, cgImage: CGImage)]) {
        guard !screenshots.isEmpty else {
            print("Capture failed: no displays produced an image")
            NSSound.beep()
            finishCapture(restorePreviousMainWindow: true)
            return
        }

        let didPresent = SelectionWindowManager.shared.presentWithCapturedScreens(
            capturedScreens: screenshots,
            onComplete: { [weak self] rect in
                guard let self else { return }

                // Extract selection from pre-captured screens
                var didSaveCapture = false
                if let result = self.extractSelectionFromCapturedScreens(rect: rect),
                   let savedURL = ImageSaver.saveImage(result) {
                    didSaveCapture = true
                    WindowManager.shared.loadImageIntoWindow(url: savedURL, shouldActivate: true)
                }

                if !didSaveCapture {
                    print("Capture failed: the selected region could not be saved")
                    NSSound.beep()
                }

                self.finishCapture(restorePreviousMainWindow: !didSaveCapture)
            }
        )

        guard didPresent else {
            print("Capture failed: selection UI was already active")
            finishCapture(restorePreviousMainWindow: true)
            return
        }
    }


    
    
    
    // Extract selection from already-captured screens (synchronous since data is already in memory)
    private func extractSelectionFromCapturedScreens(rect selectedGlobalRect: CGRect) -> NSImage? {
        guard !capturedScreens.isEmpty else { return nil }
        
        guard let bestMatch = findBestScreenMatch(for: selectedGlobalRect, in: capturedScreens) else { return nil }
        
        return extractRegion(selectedGlobalRect, from: bestMatch)
    }
    
    // MARK: - Helper Functions
    
    func triggerCapture() {
        handleSnipHotkey()
    }
    
    private func captureAllScreensImmediately() async -> [(screenInfo: ScreenInfo, cgImage: CGImage)] {
        let captureStartedAt = CACurrentMediaTime()
        var results: [(screenInfo: ScreenInfo, cgImage: CGImage)] = []
        
        do {
            let content = try await SCShareableContent.current
            
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
                        _ = CGRect(x: 0, y: 0, width: scDisplay.width, height: scDisplay.height)
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
                }
            }

            // SCScreenshotManager is designed for one-off frames, so each display
            // can be captured directly without starting and polling a video stream.
            // Run the independent display captures together so multi-monitor
            // desktops freeze at nearly the same instant.
            results = await withTaskGroup(
                of: (screenInfo: ScreenInfo, cgImage: CGImage)?.self,
                returning: [(screenInfo: ScreenInfo, cgImage: CGImage)].self
            ) { group in
                for (screenInfo, scDisplay) in matchedScreens {
                    group.addTask {
                        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                        let config = Self.makeScreenshotConfiguration(
                            for: scDisplay,
                            backingScale: screenInfo.backingScaleFactor
                        )

                        do {
                            let image = try await SCScreenshotManager.captureImage(
                                contentFilter: filter,
                                configuration: config
                            )
                            return (screenInfo: screenInfo, cgImage: image)
                        } catch {
                            print("Failed to capture display \(scDisplay.displayID): \(error)")
                            return nil
                        }
                    }
                }

                var captured: [(screenInfo: ScreenInfo, cgImage: CGImage)] = []
                for await result in group {
                    if let result {
                        captured.append(result)
                    }
                }

                // Task groups finish in completion order; restore NSScreen order
                // so panel setup and diagnostics remain deterministic.
                return captured.sorted { $0.screenInfo.index < $1.screenInfo.index }
            }
            
        } catch {
            print("Failed to capture screens: \(error)")
        }
        
        let elapsedMilliseconds = Int((CACurrentMediaTime() - captureStartedAt) * 1_000)
        print("Capture complete: \(results.count) screens in \(elapsedMilliseconds) ms")
        return results
    }

    private nonisolated static func makeScreenshotConfiguration(
        for display: SCDisplay,
        backingScale: CGFloat
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * backingScale)
        config.height = Int(CGFloat(display.height) * backingScale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        return config
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
        
        // Convert from global coordinates to screen-local coordinates (in points)
        let localRect = CGRect(
            x: intersectionRect.origin.x - screenFrame.origin.x,
            y: intersectionRect.origin.y - screenFrame.origin.y,
            width: intersectionRect.width,
            height: intersectionRect.height
        )
        
        // Since we always capture at full resolution, always use the screen scale for pixel conversion
        let pixelScale = screenScale
        
        // Convert to pixel coordinates and flip Y axis (screen coordinates are bottom-left origin, CGImage is top-left)
        let pixelRect = CGRect(
            x: localRect.origin.x * pixelScale,
            y: CGFloat(cgImage.height) - (localRect.origin.y + localRect.height) * pixelScale,
            width: localRect.width * pixelScale,
            height: localRect.height * pixelScale
        ).integral
        
        // Clamp to image bounds
        let clampedRect = CGRect(
            x: max(0, pixelRect.origin.x),
            y: max(0, pixelRect.origin.y),
            width: min(pixelRect.width, CGFloat(cgImage.width) - max(0, pixelRect.origin.x)),
            height: min(pixelRect.height, CGFloat(cgImage.height) - max(0, pixelRect.origin.y))
        )
        
        guard clampedRect.width > 0 && clampedRect.height > 0,
              let croppedCGImage = cgImage.cropping(to: clampedRect) else {
            print("Failed to crop image - invalid rect or crop operation failed")
            return nil
        }
        
        // Apply downsample setting here - affects both pixel data AND final NSImage size
        let finalPointSize: CGSize
        let finalCGImage: CGImage
        
        if !downsampleToNonRetina {
            // Keep full resolution: 2x pixels displayed at 1x point size = crisp
            finalPointSize = CGSize(
                width: clampedRect.width / screenScale,
                height: clampedRect.height / screenScale
            )
            finalCGImage = croppedCGImage
        } else {
            // Actually downsample: reduce both pixel data AND point size
            let targetPointSize = CGSize(
                width: clampedRect.width / screenScale,
                height: clampedRect.height / screenScale
            )
            
            // Create downsampled CGImage with fewer actual pixels
            if let downsampledImage = createDownsampledImage(from: croppedCGImage, to: targetPointSize) {
                finalCGImage = downsampledImage
                finalPointSize = targetPointSize
            } else {
                // Fallback if downsampling fails
                finalCGImage = croppedCGImage
                finalPointSize = targetPointSize
                print("Downsampling failed, falling back to original pixels")
            }
        }
        
        let rep = NSBitmapImageRep(cgImage: finalCGImage)
        rep.size = finalPointSize
        
        let nsImage = NSImage(size: finalPointSize)
        nsImage.addRepresentation(rep)
        
        return nsImage
    }
    
    private func createDownsampledImage(from sourceImage: CGImage, to targetPointSize: CGSize) -> CGImage? {
        let colorSpace = sourceImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        
        // Create context with the target pixel dimensions (1x resolution)
        guard let context = CGContext(
            data: nil,
            width: Int(targetPointSize.width),
            height: Int(targetPointSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            print("Failed to create downsampling context")
            return nil
        }
        
        // Use high-quality interpolation for best results when scaling down
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(origin: .zero, size: targetPointSize))
        
        return context.makeImage()
    }
    
    
    
}
