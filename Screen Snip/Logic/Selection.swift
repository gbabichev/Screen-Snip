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
    let onComplete: (CGRect) -> Void
    let onCancel: () -> Void
    
    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Create the dimmed overlay with a cut-out
                if let rect = selectionRect() {
                    // Overlay that covers everything except the selection
                    Color.black.opacity(0.3)
                        .mask(
                            Rectangle()
                                .overlay(
                                    Rectangle()
                                        .frame(width: rect.width, height: rect.height)
                                        .position(x: rect.midX, y: rect.midY)
                                        .blendMode(.destinationOut)
                                )
                        )
                    
                    // Selection border
                    Rectangle()
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)
                } else {
                    // Initial overlay before dragging starts
                    Color.black.opacity(0.1)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geo))
            .onTapGesture(count: 2) {
                // Handle double-tap cancellation
                onCancel()
            }
        }
    }
    
    private func dragGesture(in geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Keep local coordinates for correct on-screen rendering
                if startPoint == nil { startPoint = value.startLocation }
                currentPoint = value.location
            }
            .onEnded { value in
                // Convert both endpoints to global screen coords for capture math
                let gStart = globalPoint(from: value.startLocation, in: geo)
                let gEnd   = globalPoint(from: value.location, in: geo)
                let rect = buildRect(from: gStart, to: gEnd)
                startPoint = nil
                currentPoint = nil
                if let rect, rect.width > 2, rect.height > 2 {
                    onComplete(rect)
                } else {
                    onCancel()
                }
            }
    }
    
    private func globalPoint(from local: CGPoint, in geo: GeometryProxy) -> CGPoint {
        // SwiftUI local coordinates are top-left–origin with Y down.
        // Global screen coordinates are bottom-left–origin with Y up.
        return CGPoint(
            x: windowOrigin.x + local.x,
            y: windowOrigin.y + (geo.size.height - local.y)
        )
    }
    
    private func selectionRect() -> CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }
    
    private func buildRect(from start: CGPoint?, to end: CGPoint) -> CGRect? {
        guard let start else { return nil }
        return CGRect(x: min(start.x, end.x),
                      y: min(start.y, end.y),
                      width: abs(start.x - end.x),
                      height: abs(start.y - end.y))
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





