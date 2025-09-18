//
//  Selection.swift
//  Screen Snip
//
//  Created by George Babichev on 9/15/25.
//

import SwiftUI
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import UniformTypeIdentifiers
import ImageIO
import Combine


struct SelectionOverlay: View {
    let windowOrigin: CGPoint
    let capturedImage: CGImage?
    let onComplete: (CGRect) -> Void
    let onCancel: () -> Void
    
    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil
    @State private var customCursor: NSCursor?
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Display the captured static image as background
                if let capturedImage = capturedImage {
                    Image(capturedImage, scale: 1.0, label: Text("Captured Screen"))
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                
                // Create the dimmed overlay with a cut-out
                if let rect = selectionRect() {
                    // Overlay that covers everything except the selection
                    Color.black.opacity(0.4) // Slightly darker for more contrast
                        .mask(
                            Rectangle()
                                .overlay(
                                    Rectangle()
                                        .frame(width: rect.width, height: rect.height)
                                        .position(x: rect.midX, y: rect.midY)
                                        .blendMode(.destinationOut)
                                )
                        )
                    
                    // Enhanced selection border with animation
                    Rectangle()
                        .stroke(Color.white, lineWidth: 3) // White border for better visibility
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .overlay(
                            // Animated dashed border inside
                            Rectangle()
                                .stroke(Color.blue, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        )
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 0)
                    
                    // Selection size indicator
                    if rect.width > 50 && rect.height > 50 {
                        VStack(spacing: 2) {
                            Text("\(Int(rect.width)) × \(Int(rect.height))")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(4)
                        }
                        .position(x: rect.midX, y: rect.minY - 20)
                    }
                } else {
                    // Initial overlay before dragging starts
                    Color.black.opacity(0.2)
                    
                    // Instructions overlay
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                        Text("Drag to select area")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Double-click to cancel")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geo))
            .onTapGesture(count: 2) {
                onCancel()
            }
            .onAppear {
                setupCustomCursor()
            }
            .onDisappear {
                restoreDefaultCursor()
            }
        }
    }
    
    // MARK: - Custom Cursor Setup
    
    private func setupCustomCursor() {
        // Create a large orange crosshair cursor (4x larger = 128x128)
        let cursorImage = NSImage(size: NSSize(width: 128, height: 128))
        cursorImage.lockFocus()
        
        // Draw crosshair in orange
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setStrokeColor(NSColor.systemOrange.cgColor)
        ctx?.setLineWidth(8) // Thicker lines for visibility
        
        // Horizontal line (center, with gaps for the center circle)
        ctx?.move(to: CGPoint(x: 16, y: 64))
        ctx?.addLine(to: CGPoint(x: 48, y: 64))
        ctx?.move(to: CGPoint(x: 80, y: 64))
        ctx?.addLine(to: CGPoint(x: 112, y: 64))
        
        // Vertical line (center, with gaps for the center circle)
        ctx?.move(to: CGPoint(x: 64, y: 16))
        ctx?.addLine(to: CGPoint(x: 64, y: 48))
        ctx?.move(to: CGPoint(x: 64, y: 80))
        ctx?.addLine(to: CGPoint(x: 64, y: 112))
        
        ctx?.strokePath()
        
        // Add a larger center circle
        ctx?.setFillColor(NSColor.systemOrange.cgColor)
        ctx?.fillEllipse(in: CGRect(x: 56, y: 56, width: 16, height: 16))
        
        // Add a white border to the center circle for better visibility
        ctx?.setStrokeColor(NSColor.white.cgColor)
        ctx?.setLineWidth(2)
        ctx?.strokeEllipse(in: CGRect(x: 56, y: 56, width: 16, height: 16))
        
        cursorImage.unlockFocus()
        
        customCursor = NSCursor(image: cursorImage, hotSpot: NSPoint(x: 64, y: 64))
        customCursor?.push()
    }
    
    private func restoreDefaultCursor() {
        NSCursor.pop()
    }
    
    private func dragGesture(in geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if startPoint == nil {
                    startPoint = value.startLocation
                    print("Selection started at local: \(value.startLocation)")
                }
                currentPoint = value.location
            }
            .onEnded { value in
                let gStart = globalPoint(from: value.startLocation, in: geo)
                let gEnd = globalPoint(from: value.location, in: geo)
                
                print("Selection ended:")
                print("  Start local: \(value.startLocation) -> global: \(gStart)")
                print("  End local: \(value.location) -> global: \(gEnd)")
                print("  Window origin: \(windowOrigin)")
                print("  Geo size: \(geo.size)")
                
                let rect = buildRect(from: gStart, to: gEnd)
                startPoint = nil
                currentPoint = nil
                
                if let rect, rect.width > 2, rect.height > 2 {
                    print("  Final selection rect: \(rect)")
                    onComplete(rect)
                } else {
                    print("  Selection too small, canceling")
                    onCancel()
                }
            }
    }
    
    private func globalPoint(from local: CGPoint, in geo: GeometryProxy) -> CGPoint {
        // CRITICAL FIX: Handle coordinate system properly for multi-monitor
        
        // The windowOrigin is the NSWindow's frame origin, which uses AppKit coordinates
        // (bottom-left origin with Y going up)
        
        // SwiftUI local coordinates have origin at top-left with Y going down
        // We need to convert SwiftUI local -> AppKit global
        
        let globalX = windowOrigin.x + local.x
        let globalY = windowOrigin.y + (geo.size.height - local.y)
        
        let result = CGPoint(x: globalX, y: globalY)
        
        // Debug logging
        print("Coordinate conversion:")
        print("  Local: \(local)")
        print("  Window origin: \(windowOrigin)")
        print("  Geo size: \(geo.size)")
        print("  Global result: \(result)")
        
        return result
    }
    
    private func selectionRect() -> CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return CGRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(s.x - c.x),
            height: abs(s.y - c.y)
        )
    }
    
    private func buildRect(from start: CGPoint?, to end: CGPoint) -> CGRect? {
        guard let start else { return nil }
        return CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
    }
}


final class ScreenCapturer: NSObject, SCStreamOutput {
    static let shared = ScreenCapturer()
    
    private var currentStream: SCStream?
    private var captureResult: CGImage?
    private var captureError: Error?
    private var isCapturing = false
    
    func captureImage(using filter: SCContentFilter, display: SCDisplay) async -> CGImage? {
        let result = await performCapture(filter: filter, config: createConfig(for: display))
        
        // CRITICAL: Clear all references immediately after capture
        defer {
            captureResult = nil
            captureError = nil
            currentStream = nil
        }
        
        return result
    }
    
    private func createConfig(for display: SCDisplay) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        let backingScale = getBackingScaleForDisplay(display) ?? 1.0
        cfg.width = Int(CGFloat(display.width) * backingScale)
        cfg.height = Int(CGFloat(display.height) * backingScale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        return cfg
    }
    
    private func performCapture(filter: SCContentFilter, config: SCStreamConfiguration) async -> CGImage? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        
        // Clear any previous state
        captureResult = nil
        captureError = nil
        currentStream = nil
        
        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            currentStream = stream
            
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            
            // Wait for result with timeout
            let startTime = CACurrentMediaTime()
            let timeout: TimeInterval = 4.0
            
            while captureResult == nil && captureError == nil {
                if CACurrentMediaTime() - startTime > timeout {
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            
            await shutdownStream(stream)
            
            if let error = captureError {
                throw error
            }
            
            defer {
                captureResult = nil
                captureError = nil
                currentStream = nil
                // Add explicit autoreleasepool drain
                autoreleasepool {
                    // Force any retained objects to release
                }
            }
            
            return captureResult
            
        } catch {
            if let stream = currentStream {
                await shutdownStream(stream)
            }
            return nil
        }
    }
    
    private func shutdownStream(_ stream: SCStream) async {
        do {
            try stream.removeStreamOutput(self, type: .screen)
        } catch {
            // Ignore removal errors
        }
        
        do {
            try await stream.stopCapture()
        } catch let error as NSError {
            // Ignore "already stopped" errors
            if error.code != -3808 {
                print("Stream shutdown error: \(error)")
            }
        }
        
        currentStream = nil
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
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        
        if let cgImage = cgImage {
            captureResult = cgImage
        }
    }
}

final class SelectionWindowManager {
    static let shared = SelectionWindowManager()
    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    
    var onCancel: (() -> Void)?
    
    // Original method for backward compatibility (not used in new flow)
    func present(onComplete: @escaping (CGRect) -> Void) {
        guard panels.isEmpty else { return }
        
        for screen in NSScreen.screens {
            let frame = screen.frame
            let panel = NSPanel(contentRect: frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.ignoresMouseEvents = false
            panel.isMovable = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.hasShadow = false
            panel.isExcludedFromWindowsMenu = true
            panel.setFrame(frame, display: false)
            
            let root = SelectionOverlay(
                windowOrigin: frame.origin,
                capturedImage: nil,  // No captured image for old method
                onComplete: { rect in
                    onComplete(rect)
                    self.dismiss()
                },
                onCancel: {
                    self.handleCancellation()
                }
            )
                .ignoresSafeArea()
            
            panel.contentView = NSHostingView(rootView: root)
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
        }
        
        NSApp.activate(ignoringOtherApps: true)
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.handleCancellation()
                return nil
            }
            return event
        }
    }
    
    func presentWithCapturedScreens(
        capturedScreens: [(screenInfo: GlobalHotKeyManager.ScreenInfo, cgImage: CGImage)],
        onComplete: @escaping (CGRect) -> Void
    ) {
        guard panels.isEmpty else { return }
        
        print("=== Setting up selection windows ===")
        
        for (screenInfo, cgImage) in capturedScreens {
            let frame = screenInfo.frame
            print("Creating selection window for screen \(screenInfo.index):")
            print("  Frame: \(frame)")
            print("  Scale: \(screenInfo.backingScaleFactor)")
            print("  Image size: \(cgImage.width)x\(cgImage.height)")
            
            let panel = NSPanel(contentRect: frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .black
            panel.isOpaque = true
            panel.ignoresMouseEvents = false
            panel.isMovable = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.hasShadow = false
            panel.isExcludedFromWindowsMenu = true
            panel.setFrame(frame, display: false)
            
            let root = SelectionOverlay(
                windowOrigin: frame.origin,
                capturedImage: cgImage,
                onComplete: { rect in
                    print("Selection completed with rect: \(rect)")
                    onComplete(rect)
                    self.dismiss()
                },
                onCancel: {
                    print("Selection canceled")
                    self.handleCancellation()
                }
            )
                .ignoresSafeArea()
            
            panel.contentView = NSHostingView(rootView: root)
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
            
            print("  Window created and displayed")
        }
        
        NSApp.activate(ignoringOtherApps: true)
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.handleCancellation()
                return nil
            }
            return event
        }
        
        print("Selection windows ready")
    }
    
    private func handleCancellation() {
        onCancel?()
        dismiss()
    }
    
    func dismiss() {
        for p in panels {
            p.orderOut(nil)
        }
        panels.removeAll()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onCancel = nil
    }
}


