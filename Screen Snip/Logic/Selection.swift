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

// MARK: - Global Cursor Manager (NEW)
// MARK: - Global Cursor Manager (FIXED)
@MainActor
class CursorManager {
    static let shared = CursorManager()
    private var cursorStack: [NSCursor] = []
    private var cursorTimer: Timer?
    private var customCursor: NSCursor?
    
    private init() {}
    
    func setCustomCrosshairCursor() {
        // Create cursor if needed
        if self.customCursor == nil {
            // Create a large orange crosshair cursor (4x larger = 128x128)
            let cursorImage = NSImage(size: NSSize(width: 128, height: 128))
            cursorImage.lockFocus()
            
            // Draw crosshair in orange
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                ctx.setLineWidth(8) // Thicker lines for visibility
                
                // Horizontal line (center, with gaps for the center circle)
                ctx.move(to: CGPoint(x: 16, y: 64))
                ctx.addLine(to: CGPoint(x: 48, y: 64))
                ctx.move(to: CGPoint(x: 80, y: 64))
                ctx.addLine(to: CGPoint(x: 112, y: 64))
                
                // Vertical line (center, with gaps for the center circle)
                ctx.move(to: CGPoint(x: 64, y: 16))
                ctx.addLine(to: CGPoint(x: 64, y: 48))
                ctx.move(to: CGPoint(x: 64, y: 80))
                ctx.addLine(to: CGPoint(x: 64, y: 112))
                
                ctx.strokePath()
                
                // Add a larger center circle
                ctx.setFillColor(NSColor.systemOrange.cgColor)
                ctx.fillEllipse(in: CGRect(x: 56, y: 56, width: 16, height: 16))
                
                // Add a white border to the center circle for better visibility
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: 56, y: 56, width: 16, height: 16))
            }
            
            cursorImage.unlockFocus()
            
            self.customCursor = NSCursor(image: cursorImage, hotSpot: NSPoint(x: 64, y: 64))
        }
        
        // Set the cursor immediately
        self.customCursor?.set()
        
        // Start a timer to keep enforcing the cursor every 100ms
        self.cursorTimer?.invalidate()
        self.cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                // Access the cursor manager's cursor from within the MainActor context
                guard let cursor = CursorManager.shared.customCursor else { return }
                
                // Only set cursor if it's not already our custom cursor
                if NSCursor.current != cursor {
                    cursor.set()
                }
            }
        }
        
        print("Custom crosshair cursor set with enforcement timer")
    }
    
    // Force restore - use this when selection is cancelled/completed
    func forceRestoreCursor() {
        // Stop the enforcement timer immediately
        self.cursorTimer?.invalidate()
        self.cursorTimer = nil
        
        // Clear our references
        self.cursorStack.removeAll()
        
        // Force arrow cursor
        NSCursor.arrow.set()
        
        print("Cursor force restored to arrow and timer stopped")
    }
}

struct SelectionOverlay: View {
    let windowOrigin: CGPoint
    let capturedImage: CGImage?
    let onComplete: (CGRect) -> Void
    let onCancel: () -> Void
    
    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil
    
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
                        Text("Single-click or Esc to cancel")
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
                // FIXED: Ensure cursor is restored on cancel
                CursorManager.shared.forceRestoreCursor()
                onCancel()
            }
            // REMOVED: onAppear and onDisappear cursor management - now handled at window level
        }
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
                
                // FIXED: Always restore cursor when selection completes or fails
                CursorManager.shared.forceRestoreCursor()
                
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

// MARK: - SelectionWindowManager Updates
final class SelectionWindowManager {
    static let shared = SelectionWindowManager()
    private var panels: [NSPanel] = []
    private var keyMonitor: Any?
    
    var onCancel: (() -> Void)?
    
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
        
        // FIXED: Set cursor after windows are created and displayed, with a small delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            CursorManager.shared.setCustomCrosshairCursor()
        }
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape key
                self.handleCancellation()
                return nil
            }
            return event
        }
        
        print("Selection windows ready")
    }
    
    private func handleCancellation() {
        // FIXED: Ensure cursor is restored on cancellation
        CursorManager.shared.forceRestoreCursor()
        onCancel?()
        dismiss()
    }
    
    func dismiss() {
        // FIXED: Force restore cursor when dismissing selection windows
        CursorManager.shared.forceRestoreCursor()
        
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
