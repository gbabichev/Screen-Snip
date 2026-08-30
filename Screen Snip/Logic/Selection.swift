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

// MARK: - Selection Cursor
@MainActor
class CursorManager {
    static let shared = CursorManager()
    private var customCursor: NSCursor?
    
    private init() {}
    
    var crosshairCursor: NSCursor {
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

        return self.customCursor ?? .crosshair
    }

    func forceRestoreCursor() {
        NSCursor.arrow.set()
    }
}

/// Lets AppKit own the cursor for the complete selection surface. Cursor rects
/// remain active in event-tracking run-loop modes, unlike a repeating timer.
@MainActor
private final class SelectionCursorHostingView: NSHostingView<AnyView> {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: CursorManager.shared.crosshairCursor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.invalidateCursorRects(for: self)
        }
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
                    
                    //Color.black.opacity(0.2)
                    
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
final class SelectionWindowManager: NSObject {
    static let shared = SelectionWindowManager()
    private var panels: [NSPanel] = []
    private var keyMonitor: Any?

    private override init() {
        super.init()
    }
    
    var onCancel: (() -> Void)?
    var isPresentingSelection: Bool {
        !panels.isEmpty
    }
    
    func presentWithCapturedScreens(
        capturedScreens: [(screenInfo: GlobalHotKeyManager.ScreenInfo, cgImage: CGImage)],
        onComplete: @escaping (CGRect) -> Void
    ) -> Bool {
        guard panels.isEmpty, !capturedScreens.isEmpty else { return false }
        
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
                    // Remove the selection UI before image extraction, encoding,
                    // disk I/O, and editor setup begin. Running completion on the
                    // next main-loop turn also gives WindowServer a chance to
                    // display the dismissal immediately after mouse-up.
                    self.dismiss()
                    DispatchQueue.main.async {
                        onComplete(rect)
                    }
                },
                onCancel: {
                    print("Selection canceled")
                    self.handleCancellation()
                }
            )
                .ignoresSafeArea()
            
            let hostingView = SelectionCursorHostingView(rootView: AnyView(root))
            panel.contentView = hostingView
            panel.makeKeyAndOrderFront(nil)
            panel.invalidateCursorRects(for: hostingView)
            panels.append(panel)
            
            print("  Window created and displayed")
        }
        
        if NSApp.isActive {
            activateSelectionCursor()
        } else {
            // A global hotkey usually starts while another app is active. macOS
            // resets the cursor while activating Screen Snip, so install it only
            // after that transition has actually completed.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification,
                object: NSApp
            )
            NSApp.activate(ignoringOtherApps: true)
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
        return true
    }

    @objc private func applicationDidBecomeActive() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        activateSelectionCursor()
    }

    private func activateSelectionCursor() {
        for panel in panels {
            if let contentView = panel.contentView {
                panel.invalidateCursorRects(for: contentView)
            }
        }

        // Cursor rects handle subsequent movement; set immediately for a pointer
        // that was already stationary over a panel when it appeared.
        if panels.contains(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            CursorManager.shared.crosshairCursor.set()
        }
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
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        
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
