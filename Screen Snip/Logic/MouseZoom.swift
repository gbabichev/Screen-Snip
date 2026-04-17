import SwiftUI
import AppKit

final class _ZoomCatcherView: NSView {
    var zoomEnabled: Bool = true
    var onPinch: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var panEnabled: Bool = false
    private var tracking: NSTrackingArea?
    private var magnificationRecognizer: NSMagnificationGestureRecognizer?
    private var lastGestureMagnification: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTouchInput()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureTouchInput()
    }

    override var acceptsFirstResponder: Bool { true }

    private func configureTouchInput() {
        allowedTouchTypes = [.indirect]
        installMagnificationRecognizerIfNeeded()
    }

    private func installMagnificationRecognizerIfNeeded() {
        guard magnificationRecognizer == nil else { return }
        let recognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnification(_:)))
        addGestureRecognizer(recognizer)
        magnificationRecognizer = recognizer
    }

    @objc private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            lastGestureMagnification = recognizer.magnification
        case .changed:
            let delta = recognizer.magnification - lastGestureMagnification
            lastGestureMagnification = recognizer.magnification
            let location = recognizer.location(in: self)
            let anchor = CGPoint(x: location.x, y: bounds.height - location.y)
            applyPinchDelta(delta, anchor: anchor)
        case .ended, .cancelled, .failed:
            lastGestureMagnification = 0
        default:
            break
        }
    }

    private func applyPinchDelta(_ delta: CGFloat, anchor: CGPoint) {
        guard zoomEnabled else { return }
        guard delta.isFinite, delta != 0 else { return }
        let scaledDelta = delta * 2.0
        let factor = min(2.0, max(0.5, exp(scaledDelta)))
        onPinch?(factor, anchor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let ev = NSApp.currentEvent else { return nil }
        if ev.type == .magnify { return zoomEnabled ? self : nil }
        guard ev.type == .scrollWheel else { return nil }
        return (zoomEnabled && ev.modifierFlags.contains(.command)) || panEnabled ? self : nil
    }

    override func magnify(with event: NSEvent) {
        guard zoomEnabled else { return }
        let factor = min(2.0, max(0.5, exp(event.magnification * 2.0)))
        onPinch?(factor, pinchAnchorPoint(for: event))
    }

    private func pinchAnchorPoint(for event: NSEvent) -> CGPoint {
        let touches = event.touches(matching: .touching, in: self)
        if !touches.isEmpty {
            let count = CGFloat(touches.count)
            let avgX = touches.reduce(CGFloat(0)) { $0 + CGFloat($1.normalizedPosition.x) } / count
            let avgY = touches.reduce(CGFloat(0)) { $0 + CGFloat($1.normalizedPosition.y) } / count
            return CGPoint(x: avgX * bounds.width, y: (1 - avgY) * bounds.height)
        }

        let loc = convert(event.locationInWindow, from: nil)
        return CGPoint(x: loc.x, y: bounds.height - loc.y)
    }

    private func scrollAnchorPoint(for event: NSEvent) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)
        return CGPoint(x: loc.x, y: bounds.height - loc.y)
    }

    private func scrollZoomFactor(for event: NSEvent) -> CGFloat {
        let deltaY: CGFloat
        if event.hasPreciseScrollingDeltas {
            deltaY = event.scrollingDeltaY
        } else {
            deltaY = event.deltaY * 10.0
        }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.016 : 0.004
        return min(2.0, max(0.5, exp(deltaY * sensitivity)))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ensureTrackingArea()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
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
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        func scaledDeltas(for event: NSEvent) -> (x: CGFloat, y: CGFloat) {
            if event.hasPreciseScrollingDeltas {
                return (event.scrollingDeltaX, event.scrollingDeltaY)
            }
            return (event.deltaX * 10.0, event.deltaY * 10.0)
        }

        if zoomEnabled && event.modifierFlags.contains(.command) {
            onPinch?(scrollZoomFactor(for: event), scrollAnchorPoint(for: event))
            return
        }

        if panEnabled {
            let deltas = scaledDeltas(for: event)
            onPan?(deltas.x, deltas.y)
            return
        }

        super.scrollWheel(with: event)
    }
}

struct LocalScrollWheelZoomView: NSViewRepresentable {
    var zoomEnabled: Bool = true
    var onPinch: (CGFloat, CGPoint) -> Void
    var panEnabled: Bool = false
    var onPan: ((CGFloat, CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> _ZoomCatcherView {
        let v = _ZoomCatcherView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        v.zoomEnabled = zoomEnabled
        v.onPinch = onPinch
        v.panEnabled = panEnabled
        v.onPan = onPan
        return v
    }

    func updateNSView(_ nsView: _ZoomCatcherView, context: Context) {
        nsView.zoomEnabled = zoomEnabled
        nsView.onPinch = onPinch
        nsView.panEnabled = panEnabled
        nsView.onPan = onPan
    }
}
