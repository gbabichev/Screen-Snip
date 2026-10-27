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
import Carbon.HIToolbox

@MainActor
private enum CursorTrace {
#if DEBUG
    private static var sessionNumber = 0
    private static var startedAt: CFTimeInterval?

    static func begin() {
        sessionNumber += 1
        startedAt = CACurrentMediaTime()
        log("selection presentation began")
    }

    static func log(_ event: String, panels: [NSWindow] = []) {
        guard let startedAt else { return }
        let elapsed = (CACurrentMediaTime() - startedAt) * 1_000
        let keyWindow = NSApp.keyWindow.map { "\($0.windowNumber):\(type(of: $0))" } ?? "none"
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        let mouse = NSEvent.mouseLocation
        let panelState = panels.map {
            "\($0.windowNumber){key=\($0.isKeyWindow),visible=\($0.isVisible),canKey=\($0.canBecomeKey)}"
        }.joined(separator: ",")
        let cursorMatches = NSCursor.current == CursorManager.shared.crosshairCursor

        print(
            String(
                format: "[CursorTrace #%d +%.1fms] %@ | active=%@ hidden=%@ key=%@ front=%@ mouse=(%.0f,%.0f) customCurrent=%@ panels=[%@]",
                sessionNumber,
                elapsed,
                event,
                String(NSApp.isActive),
                String(NSApp.isHidden),
                keyWindow,
                frontmost,
                mouse.x,
                mouse.y,
                String(cursorMatches),
                panelState
            )
        )
    }

    static func end() {
        log("selection dismissed")
        startedAt = nil
    }
#else
    static func begin() {}
    static func log(_ event: String, panels: [NSWindow] = []) {}
    static func end() {}
#endif
}

// MARK: - Selection Cursor
@MainActor
class CursorManager {
    static let shared = CursorManager()
    private var customCursor: NSCursor?
    private var enforcementTimer: Timer?
    private var enforcementGeneration = 0
    private var loggedTimerGeneration = 0
    
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
                
                // Keep the exact target visible through a hollow center ring.
                let centerRing = CGRect(x: 54, y: 54, width: 20, height: 20)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(6)
                ctx.strokeEllipse(in: centerRing)
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                ctx.setLineWidth(3)
                ctx.strokeEllipse(in: centerRing)

                // The cursor hotspot and the dot share the same center point.
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: 60, y: 60, width: 8, height: 8))
                ctx.setFillColor(NSColor.systemOrange.cgColor)
                ctx.fillEllipse(in: CGRect(x: 62, y: 62, width: 4, height: 4))
            }
            
            cursorImage.unlockFocus()
            
            self.customCursor = NSCursor(image: cursorImage, hotSpot: NSPoint(x: 64, y: 64))
        }

        return self.customCursor ?? .crosshair
    }

    func startEnforcingCrosshairCursor() {
        enforcementTimer?.invalidate()
        enforcementGeneration += 1
        let generation = enforcementGeneration
        crosshairCursor.set()

        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                // NSCursor.current can describe this app's logical cursor even
                // while another app's arrow is still displayed. Reapply without
                // relying on that value during the short capture session.
                CursorManager.shared.crosshairCursor.set()
                if CursorManager.shared.loggedTimerGeneration != generation {
                    CursorManager.shared.loggedTimerGeneration = generation
                    CursorTrace.log("first cursor enforcement timer tick")
                }
            }
        }
        enforcementTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func forceRestoreCursor() {
        enforcementTimer?.invalidate()
        enforcementTimer = nil
        NSCursor.arrow.set()
    }
}

struct SelectionOverlay: View {
    let windowOrigin: CGPoint
    let capturedImage: CGImage?
    let magnifierEnabled: Bool
    let onComplete: (CGRect) -> Void
    let onCancel: () -> Void
    
    @State private var startPoint: CGPoint? = nil
    @State private var currentPoint: CGPoint? = nil
    @State private var hoverPoint: CGPoint? = nil

    private let magnifierDiameter: CGFloat = 180
    private let magnification: CGFloat = 4
    private let magnifierOffset: CGFloat = 145
    private let magnifierEdgePadding: CGFloat = 12
    
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

                if magnifierEnabled,
                   let capturedImage,
                   let hoverPoint,
                   CGRect(origin: .zero, size: geo.size).contains(hoverPoint) {
                    captureMagnifier(
                        image: capturedImage,
                        at: hoverPoint,
                        canvasSize: geo.size
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geo))
            .onContinuousHover { phase in
                guard magnifierEnabled else { return }
                switch phase {
                case .active(let location):
                    hoverPoint = location
                case .ended:
                    hoverPoint = nil
                }
            }
            .onAppear {
                guard magnifierEnabled else { return }
                hoverPoint = localPoint(fromGlobal: NSEvent.mouseLocation, canvasSize: geo.size)
            }
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
                    CursorTrace.log("drag gesture began")
                }
                currentPoint = value.location
                if magnifierEnabled {
                    hoverPoint = value.location
                }
            }
            .onEnded { value in
                let gStart = globalPoint(from: value.startLocation, in: geo)
                let gEnd = globalPoint(from: value.location, in: geo)
                
                let rect = buildRect(from: gStart, to: gEnd)
                startPoint = nil
                currentPoint = nil
                
                // FIXED: Always restore cursor when selection completes or fails
                CursorManager.shared.forceRestoreCursor()
                
                if let rect, rect.width > 2, rect.height > 2 {
                    CursorTrace.log("drag gesture completed")
                    onComplete(rect)
                } else {
                    CursorTrace.log("selection canceled: region too small")
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
        
        return CGPoint(x: globalX, y: globalY)
    }

    private func localPoint(fromGlobal global: CGPoint, canvasSize: CGSize) -> CGPoint? {
        let local = CGPoint(
            x: global.x - windowOrigin.x,
            y: canvasSize.height - (global.y - windowOrigin.y)
        )
        return CGRect(origin: .zero, size: canvasSize).contains(local) ? local : nil
    }

    private func captureMagnifier(
        image: CGImage,
        at point: CGPoint,
        canvasSize: CGSize
    ) -> some View {
        ZStack {
            Image(image, scale: 1.0, label: Text("Magnified capture area"))
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fill)
                .frame(
                    width: canvasSize.width * magnification,
                    height: canvasSize.height * magnification
                )
                .position(
                    x: magnifierDiameter / 2 + magnification * (canvasSize.width / 2 - point.x),
                    y: magnifierDiameter / 2 + magnification * (canvasSize.height / 2 - point.y)
                )

            magnifierCrosshair(color: .black.opacity(0.9), thickness: 7)
            magnifierCrosshair(color: .white, thickness: 3)

            Circle()
                .fill(Color.black.opacity(0.9))
                .frame(width: 10, height: 10)
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
        }
        .frame(width: magnifierDiameter, height: magnifierDiameter)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 7)
                .overlay {
                    Circle().stroke(Color.orange, lineWidth: 3)
                }
        }
        .shadow(color: .black.opacity(0.65), radius: 8, x: 0, y: 3)
        .position(magnifierCenter(for: point, canvasSize: canvasSize))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func magnifierCenter(for point: CGPoint, canvasSize: CGSize) -> CGPoint {
        let radius = magnifierDiameter / 2
        let minimumX = radius + magnifierEdgePadding
        let maximumX = canvasSize.width - radius - magnifierEdgePadding
        let minimumY = radius + magnifierEdgePadding
        let maximumY = canvasSize.height - radius - magnifierEdgePadding

        // Prefer down and to the right like Greenshot. Flip either axis when
        // needed so the loupe remains visible without covering the cursor.
        let proposedRight = point.x + magnifierOffset
        let proposedDown = point.y + magnifierOffset
        let x = proposedRight <= maximumX ? proposedRight : point.x - magnifierOffset
        let y = proposedDown <= maximumY ? proposedDown : point.y - magnifierOffset

        return CGPoint(
            x: min(max(x, minimumX), maximumX),
            y: min(max(y, minimumY), maximumY)
        )
    }

    private func magnifierCrosshair(color: Color, thickness: CGFloat) -> some View {
        let center = magnifierDiameter / 2
        let outerInset: CGFloat = 14
        let centerGap: CGFloat = 14
        let segmentLength = center - outerInset - centerGap
        let nearCenter = outerInset + segmentLength / 2

        return ZStack {
            Rectangle()
                .fill(color)
                .frame(width: segmentLength, height: thickness)
                .position(x: nearCenter, y: center)
            Rectangle()
                .fill(color)
                .frame(width: segmentLength, height: thickness)
                .position(x: magnifierDiameter - nearCenter, y: center)
            Rectangle()
                .fill(color)
                .frame(width: thickness, height: segmentLength)
                .position(x: center, y: nearCenter)
            Rectangle()
                .fill(color)
                .frame(width: thickness, height: segmentLength)
                .position(x: center, y: magnifierDiameter - nearCenter)
        }
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
    private var escapeHotKey: EventHotKeyRef?
    private var escapeEventHandler: EventHandlerRef?
    private static let escapeSignature: OSType = 0x53534553 // "SSES"

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
        CursorTrace.begin()

        for (screenInfo, cgImage) in capturedScreens {
            let frame = screenInfo.frame
            
            // Match the proven 1.4.5 behavior: the frozen selection surface is
            // intentionally visible and interactive without activating the app.
            let panel = SelectionPanel(contentRect: frame,
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
            panel.canHide = false
            panel.hasShadow = false
            panel.isExcludedFromWindowsMenu = true
            panel.setFrame(frame, display: false)
            
            let root = SelectionOverlay(
                windowOrigin: frame.origin,
                capturedImage: cgImage,
                magnifierEnabled: UserDefaults.standard.bool(forKey: "captureMagnifierEnabled"),
                onComplete: { [weak panel] rect in
                    // A canceled drag can still deliver its mouse-up callback.
                    guard let panel, self.panels.contains(where: { $0 === panel }) else { return }
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
                    CursorTrace.log("selection cancellation requested", panels: self.panels)
                    self.handleCancellation()
                }
            )
                .ignoresSafeArea()
            
            let hostingView = NSHostingView(rootView: root)
            panel.contentView = hostingView
            panel.orderFront(nil)
            panels.append(panel)
        }
        CursorTrace.log("selection panels displayed", panels: panels)
        installEscapeHotKey()

        // Preserve the activation request and delayed cursor installation order
        // used by 1.4.5. The panels themselves do not depend on activation.
        if !NSApp.isHidden {
            NSApp.activate(ignoringOtherApps: true)
        }
        let mouseLocation = NSEvent.mouseLocation
        let focusedPanel = panels.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? panels.first
        focusedPanel?.makeKey()

        // Keep the original proven fallback as well: app activation and panel
        // ordering may finish without a didBecomeActive notification (notably
        // when the editor window is hidden). Refresh after those updates settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isPresentingSelection else { return }
            CursorTrace.log("100ms activation fallback fired", panels: self.panels)
            CursorManager.shared.startEnforcingCrosshairCursor()
            CursorTrace.log("cursor enforcement started: 100ms fallback", panels: self.panels)
        }
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape key
                self.handleCancellation()
                return nil
            }
            return event
        }

        CursorTrace.log("selection input monitors installed", panels: panels)
        return true
    }

    private func handleCancellation() {
        guard !panels.isEmpty else { return }
        // FIXED: Ensure cursor is restored on cancellation
        CursorManager.shared.forceRestoreCursor()
        let cancellation = onCancel
        dismiss()
        cancellation?()
    }

    private func installEscapeHotKey() {
        // Unlike a global keyboard monitor, a registered hotkey needs no
        // Accessibility permission and works even while focus is settling.
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == SelectionWindowManager.escapeSignature,
                      hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<SelectionWindowManager>
                    .fromOpaque(userData).takeUnretainedValue()
                manager.handleCancellation()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &escapeEventHandler
        )
        guard handlerStatus == noErr else {
            print("Failed to install Escape hotkey handler: \(handlerStatus)")
            return
        }

        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            EventHotKeyID(signature: Self.escapeSignature, id: 1),
            GetApplicationEventTarget(),
            0,
            &escapeHotKey
        )
        if status != noErr {
            print("Failed to register selection Escape hotkey: \(status)")
            removeEscapeHotKey()
        }
    }

    private func removeEscapeHotKey() {
        if let escapeHotKey {
            UnregisterEventHotKey(escapeHotKey)
            self.escapeHotKey = nil
        }
        if let escapeEventHandler {
            RemoveEventHandler(escapeEventHandler)
            self.escapeEventHandler = nil
        }
    }
    
    func dismiss() {
        removeEscapeHotKey()
        CursorTrace.end()
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

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
