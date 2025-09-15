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

// MARK: - Object Editing Models
enum Handle: Hashable { case none, lineStart, lineEnd, rectTopLeft, rectTopRight, rectBottomLeft, rectBottomRight }

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
    var color: NSColor  // Add color property
    
    init(id: UUID = UUID(), rect: CGRect, width: CGFloat, color: NSColor = .black) {
        self.id = id; self.rect = rect; self.width = width; self.color = color
    }
    
    static func == (lhs: RectObject, rhs: RectObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.width == rhs.width && lhs.color == rhs.color
    }
    
    func drawPath(in _: CGSize) -> Path { Rectangle().path(in: rect) }
    
    func hitTest(_ p: CGPoint) -> Bool {
        let inset = -max(6, width + 6)
        return rect.insetBy(dx: inset, dy: inset).contains(p) && !rect.insetBy(dx: max(6, width + 6), dy: max(6, width + 6)).contains(p)
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
    
    func moved(by d: CGSize) -> RectObject { var c = self; c.rect.origin.x += d.width; c.rect.origin.y += d.height; return c }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> RectObject {
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
    
    init(id: UUID = UUID(), rect: CGRect, text: String, fontSize: CGFloat, textColor: NSColor, bgEnabled: Bool, bgColor: NSColor) {
        self.id = id; self.rect = rect; self.text = text; self.fontSize = fontSize; self.textColor = textColor; self.bgEnabled = bgEnabled; self.bgColor = bgColor
    }
    
    static func == (lhs: TextObject, rhs: TextObject) -> Bool {
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.text == rhs.text && lhs.fontSize == rhs.fontSize && lhs.textColor == rhs.textColor && lhs.bgEnabled == rhs.bgEnabled && lhs.bgColor == rhs.bgColor
    }
    
    func hitTest(_ p: CGPoint) -> Bool { rect.insetBy(dx: -6, dy: -6).contains(p) }
    
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
    
    func moved(by d: CGSize) -> TextObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> TextObject {
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
        c.rect.size.width = max(10, c.rect.size.width)
        c.rect.size.height = max(10, c.rect.size.height)
        return c
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
        lhs.id == rhs.id && lhs.rect == rhs.rect && lhs.image == rhs.image
    }
    
    func hitTest(_ p: CGPoint) -> Bool { rect.insetBy(dx: -6, dy: -6).contains(p) }
    
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
    
    func moved(by d: CGSize) -> PastedImageObject {
        var c = self
        c.rect.origin.x += d.width
        c.rect.origin.y += d.height
        return c
    }
    
    func resizing(_ handle: Handle, to p: CGPoint) -> PastedImageObject {
        var c = self
        let keepAspect = NSEvent.modifierFlags.contains(.shift)
        
        switch handle {
        case .rectTopLeft:
            c.rect = CGRect(x: p.x, y: p.y, width: rect.maxX - p.x, height: rect.maxY - p.y)
        case .rectTopRight:
            c.rect = CGRect(x: rect.minX, y: p.y, width: p.x - rect.minX, height: rect.maxY - p.y)
        case .rectBottomLeft:
            c.rect = CGRect(x: p.x, y: rect.minY, width: rect.maxX - p.x, height: p.y - rect.minY)
        case .rectBottomRight:
            c.rect = CGRect(x: rect.minX, y: rect.minY, width: p.x - rect.minX, height: p.y - rect.minY)
        default:
            break
        }
        
        c.rect.size.width  = max(8, c.rect.size.width)
        c.rect.size.height = max(8, c.rect.size.height)
        
        guard keepAspect else { return c }
        
        // Snip to original aspect by adjusting the dimension that needs the smallest change.
        let targetW = c.rect.height * aspect
        let targetH = c.rect.width / aspect
        if abs(targetW - c.rect.width) < abs(targetH - c.rect.height) {
            c.rect.size.width = targetW
        } else {
            c.rect.size.height = targetH
        }
        
        // Re-anchor based on which corner moved so the opposite corner stays fixed.
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
        return c
    }
}

struct Line: Identifiable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var width: CGFloat
}


