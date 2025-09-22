//
//  Handle.swift
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

fileprivate extension CGPoint {
    func rotated(around center: CGPoint, by angle: CGFloat) -> CGPoint {
        let s = sin(angle), co = cos(angle)
        let dx = self.x - center.x, dy = self.y - center.y
        return CGPoint(x: center.x + dx * co - dy * s,
                       y: center.y + dx * s + dy * co)
    }
}

// Angle normalization helper: returns the shortest signed angular difference from a to b
fileprivate func normalizedAngleDelta(from a: CGFloat, to b: CGFloat) -> CGFloat {
    var d = b - a
    let twoPi = CGFloat.pi * 2
    if d > .pi { d -= twoPi }
    else if d < -.pi { d += twoPi }
    return d
}

// MARK: - Object Editing Models
enum Handle: Hashable { case none, lineStart, lineEnd, rectTopLeft, rectTopRight, rectBottomLeft, rectBottomRight
case rotate }

protocol DrawableObject: Identifiable, Equatable {}

enum Drawable: Identifiable, Equatable {
    case line(LineObject)
    case rect(RectObject)
    case text(TextObject)
    case badge(BadgeObject)
    case highlight(HighlightObject)
    case image(PastedImageObject)
    case oval(OvalObject)
    
    var id: UUID {
        switch self {
        case .line(let o): return o.id
        case .rect(let o): return o.id
        case .text(let o): return o.id
        case .badge(let o): return o.id
        case .highlight(let o): return o.id
        case .image(let o): return o.id
        case .oval(let o): return o.id
        }
    }
}

struct LineObject: @MainActor DrawableObject {
    let id: UUID
    var start: CGPoint
    var end: CGPoint
    var width: CGFloat
    var arrow: Bool
    var color: NSColor  // Add color property
    
    init(id: UUID = UUID(), start: CGPoint, end: CGPoint, width: CGFloat, arrow: Bool, color: NSColor = .black) {
        self.id = id; self.start = start; self.end = end; self.width = width; self.arrow = arrow; self.color = color
    }
    
    static func == (lhs: LineObject, rhs: LineObject) -> Bool {
        lhs.id == rhs.id && lhs.start == rhs.start && lhs.end == rhs.end && lhs.width == rhs.width && lhs.arrow == rhs.arrow && lhs.color == rhs.color
    }
    
    func drawPath(in _: CGSize) -> Path { var p = Path(); p.move(to: start); p.addLine(to: end); return p }
    
    func hitTest(_ p: CGPoint) -> Bool {
        let tol = max(6, width + 6)
        let dx = end.x - start.x, dy = end.y - start.y
        let len2 = dx*dx + dy*dy
        if len2 == 0 { return hypot(p.x-start.x, p.y-start.y) <= tol }
        let t = max(0, min(1, ((p.x-start.x)*dx + (p.y-start.y)*dy)/len2))
        let proj = CGPoint(x: start.x + t*dx, y: start.y + t*dy)
        return hypot(p.x-proj.x, p.y-proj.y) <= tol
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        if CGRect(x: start.x-r, y: start.y-r, width: 2*r, height: 2*r).contains(p) { return .lineStart }
        if CGRect(x: end.x-r,   y: end.y-r,   width: 2*r, height: 2*r).contains(p) { return .lineEnd }
        return .none
    }
    
    func moved(by d: CGSize) -> LineObject {
        var c = self
        c.start.x += d.width; c.start.y += d.height
        c.end.x   += d.width; c.end.y   += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> LineObject {
        var c = self
        switch handle { case .lineStart: c.start = p; case .lineEnd: c.end = p; default: break }
        return c
    }
}

struct RectObject: @MainActor DrawableObject {
    let id: UUID
    var rect: CGRect
    var width: CGFloat
    var color: NSColor
    var rotation: CGFloat = 0
    
    init(id: UUID = UUID(), rect: CGRect, width: CGFloat, color: NSColor = .black) {
        self.id = id; self.rect = rect; self.width = width; self.color = color
    }
    
    static func == (lhs: RectObject, rhs: RectObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.width == rhs.width && lhs.color == rhs.color && lhs.rotation == rhs.rotation
    }
    
    func drawPath(in _: CGSize) -> Path {
        let p = Rectangle().path(in: rect)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        
        // Build transform: translate to origin, rotate, translate back
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: c.x, y: c.y)      // 3. Move back to center
        t = t.rotated(by: rotation)             // 2. Rotate around origin
        t = t.translatedBy(x: -c.x, y: -c.y)   // 1. Move center to origin
        
        return p.applying(t)
    }
    
    func hitTest(_ p: CGPoint) -> Bool {
        // Convert the point into the rectangle's local (unrotated) space
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let localP = p.rotated(around: c, by: -rotation)
        
        let outerInset = -max(6, width + 6)
        let innerInset =  max(6, width + 6)
        let outer = rect.insetBy(dx: outerInset, dy: outerInset)
        let inner = rect.insetBy(dx: innerInset,  dy: innerInset)
        return outer.contains(localP) && !inner.contains(localP)
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let rotateOffset: CGFloat = 20
        
        // Convert to local/unrotated space
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let lp = p.rotated(around: c, by: -rotation)
        
        // Corner handles in local space
        let tl = CGRect(x: rect.minX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        
        if tl.contains(lp) { return .rectTopLeft }
        if tr.contains(lp) { return .rectTopRight }
        if bl.contains(lp) { return .rectBottomLeft }
        if br.contains(lp) { return .rectBottomRight }
        
        // Rotate handle in local space: at (maxX + offset, minY - offset)
        let handleCenter = CGPoint(x: rect.maxX + rotateOffset, y: rect.minY - rotateOffset)
        let rotateHandle = CGRect(x: handleCenter.x - r, y: handleCenter.y - r, width: 2*r, height: 2*r)
        
        if rotateHandle.contains(lp) { return .rotate }
        
        return .none
    }
    
    /// Rotate by the shortest angular delta from prev->center to curr->center.
    func rotating(from prev: CGPoint, to curr: CGPoint) -> RectObject {
        var cpy = self
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let prevAngle = atan2(prev.y - center.y, prev.x - center.x)
        let currAngle = atan2(curr.y - center.y, curr.x - center.x)
        let d = normalizedAngleDelta(from: prevAngle, to: currAngle)
        cpy.rotation += d
        return cpy
    }
    
    func moved(by d: CGSize) -> RectObject { var c = self; c.rect.origin.x += d.width; c.rect.origin.y += d.height; return c }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> RectObject {
        var cpy = self
        let center = CGPoint(x: rect.midX, y: rect.midY)

        switch handle {
        case .rotate:
            // Check if Shift is held for 15-degree increments
            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
            let target = atan2(p.y - center.y, p.x - center.x)
            
            if shiftHeld {
                // Snap to 15-degree increments (π/12 radians)
                let increment = CGFloat.pi / 12  // 15 degrees
                let snappedTarget = round(target / increment) * increment
                let d = normalizedAngleDelta(from: cpy.rotation, to: snappedTarget)
                cpy.rotation += d
            } else {
                // Free rotation
                let d = normalizedAngleDelta(from: cpy.rotation, to: target)
                cpy.rotation += d
            }
            return cpy

        case .rectTopLeft, .rectTopRight, .rectBottomLeft, .rectBottomRight:
            // For rotated rectangles, we need to work entirely in world space
            if rotation != 0 {
                // Get the four corners of the current rectangle in world space
                let corners = [
                    CGPoint(x: rect.minX, y: rect.minY), // top-left
                    CGPoint(x: rect.maxX, y: rect.minY), // top-right
                    CGPoint(x: rect.minX, y: rect.maxY), // bottom-left
                    CGPoint(x: rect.maxX, y: rect.maxY)  // bottom-right
                ].map { $0.rotated(around: center, by: rotation) }
                
                // Determine which corner should stay fixed (opposite to the handle being dragged)
                let fixedCornerIndex: Int
                switch handle {
                case .rectTopLeft:     fixedCornerIndex = 3  // fix bottom-right
                case .rectTopRight:    fixedCornerIndex = 2  // fix bottom-left
                case .rectBottomLeft:  fixedCornerIndex = 1  // fix top-right
                case .rectBottomRight: fixedCornerIndex = 0  // fix top-left
                default: return self
                }
                
                let fixedCorner = corners[fixedCornerIndex]
                let newDragCorner = p
                
                // Calculate the new center point (midpoint between fixed corner and new drag corner)
                let newCenter = CGPoint(
                    x: (fixedCorner.x + newDragCorner.x) / 2,
                    y: (fixedCorner.y + newDragCorner.y) / 2
                )
                
                // Calculate the vector from new center to the drag corner in world space
                let dragVector = CGPoint(x: newDragCorner.x - newCenter.x, y: newDragCorner.y - newCenter.y)
                
                // Rotate this vector back to local space to get the local corner position
                let localDragCorner = dragVector.rotated(around: .zero, by: -rotation)
                
                // The new rect should be centered at origin with corners at ±localDragCorner
                let newWidth = abs(localDragCorner.x) * 2
                let newHeight = abs(localDragCorner.y) * 2
                
                // Enforce minimum size
                let minSize: CGFloat = 10
                if newWidth < minSize || newHeight < minSize {
                    return self
                }
                
                // Create the new rect centered at the new center point
                cpy.rect = CGRect(
                    x: newCenter.x - newWidth / 2,
                    y: newCenter.y - newHeight / 2,
                    width: newWidth,
                    height: newHeight
                )
                
                return cpy
            } else {
                // For non-rotated rectangles, use the original simple logic
                let lp = p
                var x0 = rect.minX, y0 = rect.minY
                var x1 = rect.maxX, y1 = rect.maxY

                switch handle {
                case .rectTopLeft:
                    x0 = lp.x; y0 = lp.y
                case .rectTopRight:
                    x1 = lp.x; y0 = lp.y
                case .rectBottomLeft:
                    x0 = lp.x; y1 = lp.y
                case .rectBottomRight:
                    x1 = lp.x; y1 = lp.y
                default: break
                }

                // Normalize in case the drag crosses the opposite corner
                let nx0 = min(x0, x1), nx1 = max(x0, x1)
                let ny0 = min(y0, y1), ny1 = max(y0, y1)
                let newWidth = nx1 - nx0
                let newHeight = ny1 - ny0
                
                // Enforce minimum size
                if newWidth < 10 || newHeight < 10 {
                    return self
                }
                
                cpy.rect = CGRect(x: nx0, y: ny0, width: newWidth, height: newHeight)
                return cpy
            }

        default:
            return self
        }
    }
    
    
}

struct OvalObject: @MainActor DrawableObject {
    let id: UUID
    var rect: CGRect
    var width: CGFloat
    var color: NSColor  // Add color property
    
    init(id: UUID = UUID(), rect: CGRect, width: CGFloat, color: NSColor = .black) {
        self.id = id
        self.rect = rect
        self.width = width
        self.color = color
    }
    
    static func == (lhs: OvalObject, rhs: OvalObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.width == rhs.width && lhs.color == rhs.color
    }

    func drawPath(in _: CGSize) -> Path {
        return Ellipse().path(in: rect)
    }
    
    func hitTest(_ p: CGPoint) -> Bool {
        // Ellipse hit test: normalize point into ellipse space and check if inside
        let rx = rect.width / 2.0
        let ry = rect.height / 2.0
        guard rx > 0, ry > 0 else { return false }
        let cx = rect.midX
        let cy = rect.midY
        let nx = (p.x - cx) / rx
        let ny = (p.y - cy) / ry
        return (nx * nx + ny * ny) <= 1.0
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }
    
    func moved(by d: CGSize) -> OvalObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> OvalObject {
        var c = self
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x,
                            y: p.y,
                            width: rect.maxX - p.x,
                            height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX,
                            y: p.y,
                            width: p.x - rect.minX,
                            height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x,
                            y: rect.minY,
                            width: rect.maxX - p.x,
                            height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX,
                            y: rect.minY,
                            width: p.x - rect.minX,
                            height: p.y - rect.minY)
        default:
            break
        }
        // Prevent negative or tiny sizes
        c.rect.size.width = max(2, c.rect.size.width)
        c.rect.size.height = max(2, c.rect.size.height)
        return c
    }
}

struct HighlightObject: @MainActor DrawableObject {
    let id: UUID
    var rect: CGRect
    var color: NSColor // include alpha for the “marker” look
    
    init(id: UUID = UUID(),
         rect: CGRect,
         color: NSColor = NSColor.systemYellow.withAlphaComponent(0.35)) {
        self.id = id; self.rect = rect; self.color = color
    }
    
    static func == (lhs: HighlightObject, rhs: HighlightObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.color == rhs.color
    }
    
    func hitTest(_ p: CGPoint) -> Bool {
        rect.insetBy(dx: -6, dy: -6).contains(p)
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }
    
    func moved(by d: CGSize) -> HighlightObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> HighlightObject {
        var c = self
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x, y: p.y, width: rect.maxX - p.x, height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX, y: p.y, width: p.x - rect.minX, height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x, y: rect.minY, width: rect.maxX - p.x, height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX, y: rect.minY, width: p.x - rect.minX, height: p.y - rect.minY)
        default: break
        }
        return c
    }
}

struct TextObject: @MainActor DrawableObject {
    let id: UUID
    var rect: CGRect
    var text: String
    var fontSize: CGFloat
    var textColor: NSColor
    var bgEnabled: Bool
    var bgColor: NSColor
    var rotation: CGFloat = 0  // Add rotation property
    
    init(id: UUID = UUID(), rect: CGRect, text: String, fontSize: CGFloat, textColor: NSColor, bgEnabled: Bool, bgColor: NSColor) {
        self.id = id; self.rect = rect; self.text = text; self.fontSize = fontSize; self.textColor = textColor; self.bgEnabled = bgEnabled; self.bgColor = bgColor
    }
    
    static func == (lhs: TextObject, rhs: TextObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.text == rhs.text && lhs.fontSize == rhs.fontSize && lhs.textColor == rhs.textColor && lhs.bgEnabled == rhs.bgEnabled && lhs.bgColor == rhs.bgColor && lhs.rotation == rhs.rotation  // Include rotation in equality
    }
    
    func hitTest(_ p: CGPoint) -> Bool {
        // Convert the point into the text box's local (unrotated) space
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let localP = p.rotated(around: c, by: -rotation)
        return rect.insetBy(dx: -6, dy: -6).contains(localP)
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let rotateOffset: CGFloat = 20

        // Convert to local/unrotated space
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let lp = p.rotated(around: c, by: -rotation)

        // Corner handles in local space
        let tl = CGRect(x: rect.minX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX-r, y: rect.minY-r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX-r, y: rect.maxY-r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX-r, y: rect.maxY-r, width: 2*r, height: 2*r)

        if tl.contains(lp) { return .rectTopLeft }
        if tr.contains(lp) { return .rectTopRight }
        if bl.contains(lp) { return .rectBottomLeft }
        if br.contains(lp) { return .rectBottomRight }

        // Rotate handle in local space: at (maxX + offset, minY - offset)
        let handleCenter = CGPoint(x: rect.maxX + rotateOffset, y: rect.minY - rotateOffset)
        let rotateHandle = CGRect(x: handleCenter.x - r, y: handleCenter.y - r, width: 2*r, height: 2*r)

        if rotateHandle.contains(lp) { return .rotate }

        return .none
    }
    
    func moved(by d: CGSize) -> TextObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> TextObject {
        var cpy = self
        let center = CGPoint(x: rect.midX, y: rect.midY)

        switch handle {
        case .rotate:
            // Use delta-based rotation like RectObject - NOT absolute angle
            // This method should only be called from pointer gesture which handles deltas
            return cpy

        case .rectTopLeft, .rectTopRight, .rectBottomLeft, .rectBottomRight:
            // Convert the drag point into local/unrotated space
            let lp = p.rotated(around: center, by: -rotation)

            var x0 = rect.minX, y0 = rect.minY
            var x1 = rect.maxX, y1 = rect.maxY

            switch handle {
            case .rectTopLeft:
                x0 = lp.x; y0 = lp.y
            case .rectTopRight:
                x1 = lp.x; y0 = lp.y
            case .rectBottomLeft:
                x0 = lp.x; y1 = lp.y
            case .rectBottomRight:
                x1 = lp.x; y1 = lp.y
            default: break
            }

            // Normalize in case the drag crosses the opposite corner
            let nx0 = min(x0, x1), nx1 = max(x0, x1)
            let ny0 = min(y0, y1), ny1 = max(y0, y1)
            cpy.rect = CGRect(x: nx0, y: ny0, width: nx1 - nx0, height: ny1 - ny0)
            
            // Maintain minimum size
            cpy.rect.size.width = max(10, cpy.rect.size.width)
            cpy.rect.size.height = max(10, cpy.rect.size.height)
            return cpy

        default:
            return self
        }
    }
    
    func rotating(from prev: CGPoint, to curr: CGPoint) -> TextObject {
        var cpy = self
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let prevAngle = atan2(prev.y - center.y, prev.x - center.x)
        let currAngle = atan2(curr.y - center.y, curr.x - center.x)
        let d = normalizedAngleDelta(from: prevAngle, to: currAngle)
        cpy.rotation += d
        return cpy
    }
    
}

struct BadgeObject: @MainActor DrawableObject {
    let id: UUID
    var rect: CGRect
    var number: Int
    var fillColor: NSColor
    var textColor: NSColor
    
    init(id: UUID = UUID(), rect: CGRect, number: Int, fillColor: NSColor, textColor: NSColor) {
        self.id = id; self.rect = rect; self.number = number; self.fillColor = fillColor; self.textColor = textColor
    }
    
    static func == (lhs: BadgeObject, rhs: BadgeObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.number == rhs.number && lhs.fillColor == rhs.fillColor && lhs.textColor == rhs.textColor
    }
    
    func hitTest(_ p: CGPoint) -> Bool {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let radius = max(rect.width, rect.height) / 2 + 6
        return hypot(p.x - c.x, p.y - c.y) <= radius
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let tl = CGRect(x: rect.minX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        if tl.contains(p) { return .rectTopLeft }
        if tr.contains(p) { return .rectTopRight }
        if bl.contains(p) { return .rectBottomLeft }
        if br.contains(p) { return .rectBottomRight }
        return .none
    }
    
    func moved(by d: CGSize) -> BadgeObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> BadgeObject {
        var c = self
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x, y: p.y, width: rect.maxX - p.x, height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX, y: p.y, width: p.x - rect.minX, height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x, y: rect.minY, width: rect.maxX - p.x, height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX, y: rect.minY, width: p.x - rect.minX, height: p.y - rect.minY)
        default: break
        }
        let side = max(8, (c.rect.width + c.rect.height) / 2)
        c.rect.size = CGSize(width: side, height: side)
        return c
    }
}

struct PastedImageObject: @MainActor DrawableObject {
    let id: UUID
    var rect: CGRect
    var image: NSImage
    var rotation: CGFloat = 0  // Add rotation property
    /// Natural aspect ratio (w / h) for Shift-resize.
    let aspect: CGFloat
    
    init(id: UUID = UUID(), rect: CGRect, image: NSImage) {
        self.id = id
        self.rect = rect
        self.image = image
        let s = image.size
        self.aspect = (s.height == 0) ? 1 : (s.width / s.height)
    }
    
    static func == (lhs: PastedImageObject, rhs: PastedImageObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.image == rhs.image && lhs.rotation == rhs.rotation  // Include rotation in equality
    }
    
    func hitTest(_ p: CGPoint) -> Bool {
        // Convert the point into the image's local (unrotated) space
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let localP = p.rotated(around: c, by: -rotation)
        return rect.insetBy(dx: -6, dy: -6).contains(localP)
    }
    
    func handleHitTest(_ p: CGPoint) -> Handle {
        let r: CGFloat = 8
        let rotateOffset: CGFloat = 20
        
        // Convert to local/unrotated space
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let lp = p.rotated(around: c, by: -rotation)
        
        // Corner handles in local space
        let tl = CGRect(x: rect.minX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let tr = CGRect(x: rect.maxX - r, y: rect.minY - r, width: 2*r, height: 2*r)
        let bl = CGRect(x: rect.minX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        let br = CGRect(x: rect.maxX - r, y: rect.maxY - r, width: 2*r, height: 2*r)
        
        if tl.contains(lp) { return .rectTopLeft }
        if tr.contains(lp) { return .rectTopRight }
        if bl.contains(lp) { return .rectBottomLeft }
        if br.contains(lp) { return .rectBottomRight }
        
        // Rotate handle in local space: at (maxX + offset, minY - offset)
        let handleCenter = CGPoint(x: rect.maxX + rotateOffset, y: rect.minY - rotateOffset)
        let rotateHandle = CGRect(x: handleCenter.x - r, y: handleCenter.y - r, width: 2*r, height: 2*r)
        
        if rotateHandle.contains(lp) { return .rotate }
        
        return .none
    }
    
    func moved(by d: CGSize) -> PastedImageObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    /// Rotate by the shortest angular delta from prev->center to curr->center.
    func rotating(from prev: CGPoint, to curr: CGPoint) -> PastedImageObject {
        var cpy = self
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let prevAngle = atan2(prev.y - center.y, prev.x - center.x)
        let currAngle = atan2(curr.y - center.y, curr.x - center.x)
        let d = normalizedAngleDelta(from: prevAngle, to: currAngle)
        cpy.rotation += d
        return cpy
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> PastedImageObject {
        var c = self
        let keepAspect = NSEvent.modifierFlags.contains(.shift)
        let center = CGPoint(x: rect.midX, y: rect.midY)

        switch handle {
        case .rotate:
            // Adjust by the shortest delta from current rotation to target pointer angle
            let target = atan2(p.y - center.y, p.x - center.x)
            let d = normalizedAngleDelta(from: c.rotation, to: target)
            c.rotation += d
            return c

        case .rectTopLeft, .rectTopRight, .rectBottomLeft, .rectBottomRight:
            // For rotated images, we need to work entirely in world space
            if rotation != 0 {
                // Get the four corners of the current image in world space
                let corners = [
                    CGPoint(x: rect.minX, y: rect.minY), // top-left
                    CGPoint(x: rect.maxX, y: rect.minY), // top-right
                    CGPoint(x: rect.minX, y: rect.maxY), // bottom-left
                    CGPoint(x: rect.maxX, y: rect.maxY)  // bottom-right
                ].map { $0.rotated(around: center, by: rotation) }
                
                // Determine which corner should stay fixed (opposite to the handle being dragged)
                let fixedCornerIndex: Int
                switch handle {
                case .rectTopLeft:     fixedCornerIndex = 3  // fix bottom-right
                case .rectTopRight:    fixedCornerIndex = 2  // fix bottom-left
                case .rectBottomLeft:  fixedCornerIndex = 1  // fix top-right
                case .rectBottomRight: fixedCornerIndex = 0  // fix top-left
                default: return self
                }
                
                let fixedCorner = corners[fixedCornerIndex]
                let newDragCorner = p
                
                // Calculate the new center point (midpoint between fixed corner and new drag corner)
                let newCenter = CGPoint(
                    x: (fixedCorner.x + newDragCorner.x) / 2,
                    y: (fixedCorner.y + newDragCorner.y) / 2
                )
                
                // Calculate the vector from new center to the drag corner in world space
                let dragVector = CGPoint(x: newDragCorner.x - newCenter.x, y: newDragCorner.y - newCenter.y)
                
                // Rotate this vector back to local space to get the local corner position
                let localDragCorner = dragVector.rotated(around: .zero, by: -rotation)
                
                // The new rect should be centered at origin with corners at ±localDragCorner
                let newWidth = abs(localDragCorner.x) * 2
                let newHeight = abs(localDragCorner.y) * 2
                
                // Enforce minimum size
                let minSize: CGFloat = 8
                if newWidth < minSize || newHeight < minSize {
                    return self
                }
                
                // Handle aspect ratio constraint for rotated images
                var finalWidth = newWidth
                var finalHeight = newHeight
                
                if keepAspect {
                    let currentAspect = finalWidth / finalHeight
                    if abs(currentAspect - aspect) > 0.01 {
                        // Decide whether to constrain by width or height based on which requires less change
                        let targetWidthFromHeight = finalHeight * aspect
                        let targetHeightFromWidth = finalWidth / aspect
                        
                        if abs(targetWidthFromHeight - finalWidth) < abs(targetHeightFromWidth - finalHeight) {
                            finalWidth = targetWidthFromHeight
                        } else {
                            finalHeight = targetHeightFromWidth
                        }
                        
                        // Ensure we still meet minimum size after aspect correction
                        if finalWidth < minSize || finalHeight < minSize {
                            if finalWidth < minSize {
                                finalWidth = minSize
                                finalHeight = finalWidth / aspect
                            } else {
                                finalHeight = minSize
                                finalWidth = finalHeight * aspect
                            }
                        }
                    }
                }
                
                // Create the new rect centered at the new center point
                c.rect = CGRect(
                    x: newCenter.x - finalWidth / 2,
                    y: newCenter.y - finalHeight / 2,
                    width: finalWidth,
                    height: finalHeight
                )
                
                return c
            } else {
                // For non-rotated images, use the original simple logic
                let lp = p
                var x0 = rect.minX, y0 = rect.minY
                var x1 = rect.maxX, y1 = rect.maxY

                switch handle {
                case .rectTopLeft:
                    x0 = lp.x; y0 = lp.y
                case .rectTopRight:
                    x1 = lp.x; y0 = lp.y
                case .rectBottomLeft:
                    x0 = lp.x; y1 = lp.y
                case .rectBottomRight:
                    x1 = lp.x; y1 = lp.y
                default: break
                }

                // Normalize in case the drag crosses the opposite corner
                let nx0 = min(x0, x1), nx1 = max(x0, x1)
                let ny0 = min(y0, y1), ny1 = max(y0, y1)
                let newWidth = nx1 - nx0
                let newHeight = ny1 - ny0
                
                // Enforce minimum size
                if newWidth < 8 || newHeight < 8 {
                    return self
                }
                
                c.rect = CGRect(x: nx0, y: ny0, width: newWidth, height: newHeight)
                
                // Apply aspect ratio constraint for non-rotated images
                if keepAspect {
                    let currentAspect = c.rect.width / c.rect.height
                    if abs(currentAspect - aspect) > 0.01 {
                        // Snap to original aspect by adjusting the dimension that needs the smallest change
                        let targetW = c.rect.height * aspect
                        let targetH = c.rect.width / aspect
                        if abs(targetW - c.rect.width) < abs(targetH - c.rect.height) {
                            c.rect.size.width = targetW
                        } else {
                            c.rect.size.height = targetH
                        }
                        
                        // Re-anchor based on which corner moved so the opposite corner stays fixed
                        switch handle {
                        case .rectTopLeft:
                            c.rect.origin.x = rect.maxX - c.rect.size.width
                            c.rect.origin.y = rect.maxY - c.rect.size.height
                        case .rectTopRight:
                            c.rect.origin.y = rect.maxY - c.rect.size.height
                        case .rectBottomLeft:
                            c.rect.origin.x = rect.maxX - c.rect.size.width
                        default:
                            break
                        }
                    }
                }
                
                return c
            }

        default:
            return self
        }
    }
    
    
}

struct Line: Identifiable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var width: CGFloat
}


