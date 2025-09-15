
//
//  MouseZOom.swift
//  Screen Snip
//
//  Created by George Babichev on 9/15/25.
//

import SwiftUI

// A view-scoped scroll wheel handler that only reacts when the mouse is over THIS view.
final class _ZoomCatcherView: NSView {
    var onZoom: ((CGFloat) -> Void)?
    private var tracking: NSTrackingArea?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only become the hit-test target when the Command key is held.
        // This lets trackpad pinch (magnify) reach the SwiftUI image beneath.
        if let ev = NSApp.currentEvent, ev.modifierFlags.contains(.command) {
            return self
        }
        return nil
    }
    
    override func magnify(with event: NSEvent) {
        // Do not consume pinch-to-zoom; forward it so SwiftUI's MagnificationGesture works.
        nextResponder?.magnify(with: event)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureTrackingArea()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        ensureTrackingArea()
    }
    
    private func ensureTrackingArea() {
        if let tracking { removeTrackingArea(tracking) }
        let opts: NSTrackingArea.Options = [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        window?.makeFirstResponder(self)
    }
    
    override func mouseDown(with event: NSEvent) {
        // Also claim first responder on click
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    
    override func scrollWheel(with event: NSEvent) {
        // Only handle when Command is held; otherwise pass through
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        
        let deltaY: CGFloat
        if event.hasPreciseScrollingDeltas {
            deltaY = event.scrollingDeltaY
        } else {
            // Non-precise mouse: scale a bit per line step
            deltaY = event.deltaY * 10.0
        }
        
        // Convert delta into a multiplicative zoom factor
        // Small base so both trackpads and wheels feel reasonable
        let factor = pow(1.0018, deltaY)
        onZoom?(factor)
    }
}

struct LocalScrollWheelZoomView: NSViewRepresentable {
    @Binding var zoomLevel: Double
    var minZoom: Double = 0.1
    var maxZoom: Double = 3.0
    
    func makeNSView(context: Context) -> _ZoomCatcherView {
        let v = _ZoomCatcherView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        v.onZoom = { factor in
            let newZoom = min(max(zoomLevel * Double(factor), minZoom), maxZoom)
            zoomLevel = newZoom
        }
        return v
    }
    
    func updateNSView(_ nsView: _ZoomCatcherView, context: Context) {
        // Update the zoom handler with current zoom level
        nsView.onZoom = { factor in
            let newZoom = min(max(zoomLevel * Double(factor), minZoom), maxZoom)
            zoomLevel = newZoom
        }
    }
}
