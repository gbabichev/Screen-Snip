import SwiftUI

extension ContentView {
    func pointerGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let pFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let p = fittedToAuthorPoint(pFit, fitted: fitted, author: author)
                if dragStartPoint == nil {
                    dragStartPoint = p

                    // First check if clicking inside multi-selection bounding box
                    if !selectedObjectIDs.isEmpty, let boundingBox = boundingBoxOfSelectedObjects(), boundingBox.contains(p) {
                        // Clicked inside bounding box of multi-selection - prepare to move all
                        selectedObjectID = nil  // Don't show single selection handles
                        activeHandle = .none
                        focusedTextID = nil
                    } else if let idx = objects.firstIndex(where: { obj in
                        switch obj {
                        case .line(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .rect(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .oval(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .text(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .badge(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .highlight(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .image(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        case .blur(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        }
                    }) {
                        let clickedID = objects[idx].id
                        // Check if clicked object is part of multi-selection
                        if !selectedObjectIDs.isEmpty && selectedObjectIDs.contains(clickedID) {
                            // Clicked on a multi-selected object - prepare to move all
                            selectedObjectID = nil  // Don't show single selection handles
                            activeHandle = .none
                        } else {
                            // Single object selection
                            selectedObjectID = clickedID
                            selectedObjectIDs.removeAll()  // Clear multi-selection
                            switch objects[idx] {
                            case .line(let o): activeHandle = o.handleHitTest(p)
                            case .rect(let o): activeHandle = o.handleHitTest(p)
                            case .oval(let o): activeHandle = o.handleHitTest(p)
                            case .text(let o): activeHandle = o.handleHitTest(p)
                            case .badge(let o): activeHandle = o.handleHitTest(p)
                            case .highlight(let o): activeHandle = o.handleHitTest(p)
                            case .image(let o): activeHandle = o.handleHitTest(p)
                            case .blur(let o): activeHandle = o.handleHitTest(p)
                            }
                        }
                        // On single click or drag, always clear focus (do not enter edit mode)
                        focusedTextID = nil

                    } else {
                        // No object clicked - start selection rectangle
                        selectedObjectID = nil
                        activeHandle = .none
                        focusedTextID = nil
                        selectionDragStart = p
                        selectedObjectIDs.removeAll()
                    }
                } else if let selStart = selectionDragStart {
                    // Update selection rectangle
                    let minX = min(selStart.x, p.x)
                    let minY = min(selStart.y, p.y)
                    let maxX = max(selStart.x, p.x)
                    let maxY = max(selStart.y, p.y)
                    selectionRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                } else if !selectedObjectIDs.isEmpty, let start = dragStartPoint {
                    // Move all selected objects
                    let desiredDelta = CGSize(width: p.x - start.x, height: p.y - start.y)
                    if !pushedDragUndo {
                        pushUndoSnipshot()
                        pushedDragUndo = true
                    }

                    var resolvedDelta = desiredDelta
                    var selectedIndices: [Int] = []

                    for idx in objects.indices where selectedObjectIDs.contains(objects[idx].id) {
                        selectedIndices.append(idx)

                        let allowed: CGSize
                        switch objects[idx] {
                        case .line(let o):
                            allowed = clampedDeltaForLine(o, delta: desiredDelta, in: author)
                        case .rect(let o):
                            allowed = o.rotation != 0
                                ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: desiredDelta, in: author)
                                : clampedDeltaForRect(o.rect, delta: desiredDelta, in: author)
                        case .oval(let o):
                            allowed = clampedDeltaForRect(o.rect, delta: desiredDelta, in: author)
                        case .text(let o):
                            allowed = o.rotation != 0
                                ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: desiredDelta, in: author)
                                : clampedDeltaForRect(o.rect, delta: desiredDelta, in: author)
                        case .badge(let o):
                            allowed = clampedDeltaForRect(o.rect, delta: desiredDelta, in: author)
                        case .highlight(let o):
                            allowed = clampedDeltaForRect(o.rect, delta: desiredDelta, in: author)
                        case .image(let o):
                            allowed = o.rotation != 0
                                ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: desiredDelta, in: author)
                                : clampedDeltaForRect(o.rect, delta: desiredDelta, in: author)
                        case .blur(let o):
                            allowed = o.rotation != 0
                                ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: desiredDelta, in: author)
                                : clampedDeltaForRect(o.rect, delta: desiredDelta, in: author)
                        }

                        resolvedDelta.width = adjustedDeltaComponent(desired: desiredDelta.width, current: resolvedDelta.width, allowed: allowed.width)
                        resolvedDelta.height = adjustedDeltaComponent(desired: desiredDelta.height, current: resolvedDelta.height, allowed: allowed.height)
                    }

                    if resolvedDelta.width != 0 || resolvedDelta.height != 0 {
                        for idx in selectedIndices {
                            switch objects[idx] {
                            case .line(var o):
                                o = o.moved(by: resolvedDelta)
                                objects[idx] = .line(o)
                            case .rect(var o):
                                o = o.moved(by: resolvedDelta)
                                objects[idx] = .rect(o)
                            case .oval(var o):
                                o = o.moved(by: resolvedDelta)
                                objects[idx] = .oval(o)
                            case .text(var o):
                                o = o.moved(by: resolvedDelta)
                                objects[idx] = .text(o)
                            case .badge(var o):
                                o = o.moved(by: resolvedDelta)
                                objects[idx] = .badge(o)
                            case .highlight(var o):
                                o = o.moved(by: resolvedDelta)
                                objects[idx] = .highlight(o)
                            case .image(var o):
                                o = o.moved(by: resolvedDelta)
                                objects[idx] = .image(o)
                            case .blur(var o):
                                o = o.moved(by: resolvedDelta)
                                objects[idx] = .blur(o)
                            }
                        }
                    }

                    dragStartPoint = p
                } else if let sel = selectedObjectID, let start = dragStartPoint, let idx = objects.firstIndex(where: { $0.id == sel }) {
                    let delta = CGSize(width: p.x - start.x, height: p.y - start.y)
                    if !pushedDragUndo {
                        pushUndoSnipshot()
                        pushedDragUndo = true
                    }
                    switch objects[idx] {
                    case .line(let o):
                        if activeHandle == .none {
                            // Move whole line without warping — clamp the delta so both endpoints remain inside the canvas
                            // Clamp X
                            let proposedStartX = o.start.x + delta.width
                            let proposedEndX   = o.end.x   + delta.width
                            var dx = delta.width
                            let minX = min(proposedStartX, proposedEndX)
                            let maxX = max(proposedStartX, proposedEndX)
                            if minX < 0 { dx -= minX }
                            if maxX > author.width { dx -= (maxX - author.width) }
                            // Clamp Y
                            let proposedStartY = o.start.y + delta.height
                            let proposedEndY   = o.end.y   + delta.height
                            var dy = delta.height
                            let minY = min(proposedStartY, proposedEndY)
                            let maxY = max(proposedStartY, proposedEndY)
                            if minY < 0 { dy -= minY }
                            if maxY > author.height { dy -= (maxY - author.height) }
                            let clampedDelta = CGSize(width: dx, height: dy)
                            let moved = o.moved(by: clampedDelta)
                            objects[idx] = .line(moved)
                        } else {
                            // Resizing endpoint: clamp that endpoint after resize
                            var updated = o.resizing(activeHandle, to: p)
                            updated.start = clampPoint(updated.start, in: author)
                            updated.end   = clampPoint(updated.end,   in: author)
                            objects[idx] = .line(updated)
                        }
                    case .rect(let o):
                        var updated = o
                        if activeHandle == .none {
                            // Clamp delta before moving to prevent going off-canvas (works for both rotated and non-rotated)
                            let moveDelta = o.rotation != 0
                                ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: delta, in: author)
                                : clampedDeltaForRect(o.rect, delta: delta, in: author)
                            updated = o.moved(by: moveDelta)
                        } else if activeHandle == .rotate {
                            // Absolute-angle rotation anchored at gesture begin; no per-tick anchor drift
                            let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

                            // Initialize anchors on first rotate tick for this drag
                            if rectRotateStartAngle == nil || rectRotateStartValue == nil {
                                // Use the initial dragStartPoint as the pointer anchor at mouse-down
                                if let s = dragStartPoint {
                                    rectRotateStartAngle = atan2(s.y - c.y, s.x - c.x)
                                } else {
                                    rectRotateStartAngle = atan2(p.y - c.y, p.x - c.x)
                                }
                                rectRotateStartValue = o.rotation
                            }

                            guard let startAngle = rectRotateStartAngle, let baseRotation = rectRotateStartValue else {
                                return
                            }

                            // Current pointer angle
                            let currAngle = atan2(p.y - c.y, p.x - c.x)

                            // Absolute target = base rotation + delta from initial pointer angle to current pointer angle
                            var target = baseRotation + normalizedAngleDelta(from: startAngle, to: currAngle)

                            // Modifier-based snapping: Option=1°, Command=5°, Shift=15°; none=free
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.option) {
                                let inc = CGFloat.pi / 180 // 1°
                                target = round(target / inc) * inc
                            } else if mods.contains(.command) {
                                let inc = CGFloat.pi / 36 // 5°
                                target = round(target / inc) * inc
                            } else if mods.contains(.shift) {
                                let inc = CGFloat.pi / 12 // 15°
                                target = round(target / inc) * inc
                            }

                            updated.rotation = target

                            // Do NOT clamp rect while rotating; geometry doesn't change
                            objects[idx] = .rect(updated)
                            // Important: keep anchors stable; do not mutate dragStartPoint here
                            return
                        } else {
                            // For resizing, use unclamped point for rotated objects (clamping before resize breaks the math)
                            let resizePoint = o.rotation != 0 ? p : clampPoint(p, in: author)
                            let resized = o.resizing(activeHandle, to: resizePoint)

                            // For rotated objects, check if resize would go off-canvas
                            if o.rotation != 0 {
                                // Only apply resize if it stays within bounds
                                if rotatedRectFitsInBounds(resized.rect, rotation: resized.rotation, in: author) {
                                    updated = resized
                                }
                                // If it doesn't fit, keep the old rect (updated = o, which was set earlier)
                            } else {
                                // For non-rotated, apply normal clamping
                                updated = resized
                                updated.rect = clampRect(updated.rect, in: author)
                            }
                        }
                        objects[idx] = .rect(updated)
                    case .oval(let o):
                        let clampedP = clampPoint(p, in: author)
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: clampedP)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .oval(u)
                    case .text(let o):
                        var updated = o
                        if activeHandle == .none {
                            // Clamp delta before moving to prevent going off-canvas (works for both rotated and non-rotated)
                            let moveDelta = o.rotation != 0
                                ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: delta, in: author)
                                : clampedDeltaForRect(o.rect, delta: delta, in: author)
                            updated = o.moved(by: moveDelta)
                        } else if activeHandle == .rotate {
                            // Absolute-angle rotation anchored at gesture begin; no per-tick anchor drift
                            let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

                            // Initialize anchors on first rotate tick for this drag
                            if textRotateStartAngle == nil || textRotateStartValue == nil {
                                // Use the initial dragStartPoint as the pointer anchor at mouse-down
                                if let s = dragStartPoint {
                                    textRotateStartAngle = atan2(s.y - c.y, s.x - c.x)
                                } else {
                                    textRotateStartAngle = atan2(p.y - c.y, p.x - c.x)
                                }
                                textRotateStartValue = o.rotation
                            }

                            guard let startAngle = textRotateStartAngle, let baseRotation = textRotateStartValue else {
                                return
                            }

                            // Current pointer angle
                            let currAngle = atan2(p.y - c.y, p.x - c.x)

                            // Absolute target = base rotation + delta from initial pointer angle to current pointer angle
                            var target = baseRotation + normalizedAngleDelta(from: startAngle, to: currAngle)

                            // Modifier-based snapping: Option=1°, Command=5°, Shift=15°; none=free
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.option) {
                                let inc = CGFloat.pi / 180 // 1°
                                target = round(target / inc) * inc
                            } else if mods.contains(.command) {
                                let inc = CGFloat.pi / 36 // 5°
                                target = round(target / inc) * inc
                            } else if mods.contains(.shift) {
                                let inc = CGFloat.pi / 12 // 15°
                                target = round(target / inc) * inc
                            }

                            updated.rotation = target

                            objects[idx] = .text(updated)
                            // Important: keep anchors stable; do not mutate dragStartPoint here
                            return
                        } else {
                            // For resizing, use unclamped point for rotated objects (clamping before resize breaks the math)
                            let resizePoint = o.rotation != 0 ? p : clampPoint(p, in: author)
                            let resized = o.resizing(activeHandle, to: resizePoint)

                            // For rotated objects, check if resize would go off-canvas
                            if o.rotation != 0 {
                                // Only apply resize if it stays within bounds
                                if rotatedRectFitsInBounds(resized.rect, rotation: resized.rotation, in: author) {
                                    updated = resized
                                }
                                // If it doesn't fit, keep the old rect (updated = o, which was set earlier)
                            } else {
                                // For non-rotated, apply normal clamping
                                updated = resized
                                updated.rect = clampRect(updated.rect, in: author)
                            }
                        }
                        objects[idx] = .text(updated)
                    case .badge(let o):
                        let clampedP = clampPoint(p, in: author)
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: clampedP)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .badge(u)
                    case .highlight(let o):
                        let clampedP = clampPoint(p, in: author)
                        let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: clampedP)
                        let clamped = clampRect(updated.rect, in: author)
                        var u = updated; u.rect = clamped
                        objects[idx] = .highlight(u)
                    case .image(let o):
                        var updated = o
                        if activeHandle == .none {
                            // Clamp delta before moving to prevent going off-canvas (works for both rotated and non-rotated)
                            let moveDelta = o.rotation != 0
                                ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: delta, in: author)
                                : clampedDeltaForRect(o.rect, delta: delta, in: author)
                            updated = o.moved(by: moveDelta)
                        } else if activeHandle == .rotate {
                            // Absolute-angle rotation anchored at gesture begin; no per-tick anchor drift
                            let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

                            // Initialize anchors on first rotate tick for this drag
                            if imageRotateStartAngle == nil || imageRotateStartValue == nil {
                                if let s = dragStartPoint {
                                    imageRotateStartAngle = atan2(s.y - c.y, s.x - c.x)
                                } else {
                                    imageRotateStartAngle = atan2(p.y - c.y, p.x - c.x)
                                }
                                imageRotateStartValue = o.rotation
                            }

                            guard let startAngle = imageRotateStartAngle, let baseRotation = imageRotateStartValue else {
                                return
                            }

                            // Current pointer angle
                            let currAngle = atan2(p.y - c.y, p.x - c.x)

                            // Absolute target = base rotation + delta from initial pointer angle to current pointer angle
                            var target = baseRotation + normalizedAngleDelta(from: startAngle, to: currAngle)

                            // Modifier-based snapping: Option=1°, Command=5°, Shift=15°; none=free
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.option) {
                                let inc = CGFloat.pi / 180 // 1°
                                target = round(target / inc) * inc
                            } else if mods.contains(.command) {
                                let inc = CGFloat.pi / 36  // 5°
                                target = round(target / inc) * inc
                            } else if mods.contains(.shift) {
                                let inc = CGFloat.pi / 12  // 15°
                                target = round(target / inc) * inc
                            }

                            updated.rotation = target
                            objects[idx] = .image(updated)
                            // Important: keep anchors stable; do not mutate dragStartPoint here
                            return
                        } else {
                            // For resizing, use unclamped point for rotated objects (clamping before resize breaks the math)
                            let resizePoint = o.rotation != 0 ? p : clampPoint(p, in: author)
                            let resized = o.resizing(activeHandle, to: resizePoint)

                            // For rotated objects, check if resize would go off-canvas
                            if o.rotation != 0 {
                                // Only apply resize if it stays within bounds
                                if rotatedRectFitsInBounds(resized.rect, rotation: resized.rotation, in: author) {
                                    updated = resized
                                }
                                // If it doesn't fit, keep the old rect (updated = o, which was set earlier)
                            } else {
                                // For non-rotated, apply normal clamping
                                updated = resized
                                updated.rect = clampRect(updated.rect, in: author)
                            }
                        }
                        objects[idx] = .image(updated)
                    case .blur(let o):
                        var updated = o
                        if activeHandle == .none {
                            // Clamp delta before moving to prevent going off-canvas (works for both rotated and non-rotated)
                            let moveDelta = o.rotation != 0
                                ? clampedDeltaForRotatedRect(o.rect, rotation: o.rotation, delta: delta, in: author)
                                : clampedDeltaForRect(o.rect, delta: delta, in: author)
                            updated = o.moved(by: moveDelta)
                        } else if activeHandle == .rotate {
                            // Absolute-angle rotation anchored at gesture begin; no per-tick anchor drift
                            let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

                            // Initialize anchors on first rotate tick for this drag
                            if rectRotateStartAngle == nil || rectRotateStartValue == nil {
                                if let s = dragStartPoint {
                                    rectRotateStartAngle = atan2(s.y - c.y, s.x - c.x)
                                } else {
                                    rectRotateStartAngle = atan2(p.y - c.y, p.x - c.x)
                                }
                                rectRotateStartValue = o.rotation
                            }

                            guard let startAngle = rectRotateStartAngle, let baseRotation = rectRotateStartValue else {
                                return
                            }

                            // Current pointer angle
                            let currAngle = atan2(p.y - c.y, p.x - c.x)

                            // Absolute target = base rotation + delta from initial pointer angle to current pointer angle
                            var target = baseRotation + normalizedAngleDelta(from: startAngle, to: currAngle)

                            // Modifier-based snapping: Option=1°, Command=5°, Shift=15°; none=free
                            let mods = NSEvent.modifierFlags
                            if mods.contains(.option) {
                                let inc = CGFloat.pi / 180 // 1°
                                target = round(target / inc) * inc
                            } else if mods.contains(.command) {
                                let inc = CGFloat.pi / 36  // 5°
                                target = round(target / inc) * inc
                            } else if mods.contains(.shift) {
                                let inc = CGFloat.pi / 12  // 15°
                                target = round(target / inc) * inc
                            }

                            updated.rotation = target
                            objects[idx] = .blur(updated)
                            // Important: keep anchors stable; do not mutate dragStartPoint here
                            return
                        } else {
                            // For resizing, use unclamped point for rotated objects (clamping before resize breaks the math)
                            let resizePoint = o.rotation != 0 ? p : clampPoint(p, in: author)
                            let resized = o.resizing(activeHandle, to: resizePoint)

                            // For rotated objects, check if resize would go off-canvas
                            if o.rotation != 0 {
                                // Only apply resize if it stays within bounds
                                if rotatedRectFitsInBounds(resized.rect, rotation: resized.rotation, in: author) {
                                    updated = resized
                                }
                                // If it doesn't fit, keep the old rect (updated = o, which was set earlier)
                            } else {
                                // For non-rotated, apply normal clamping
                                updated = resized
                                updated.rect = clampRect(updated.rect, in: author)
                            }
                        }
                        objects[idx] = .blur(updated)
                    }
                    dragStartPoint = p
                }
            }
            .onEnded { value in  // Add 'value in' parameter here
                let endFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let pEnd = fittedToAuthorPoint(endFit, fitted: fitted, author: author)
                let pStart = fittedToAuthorPoint(startFit, fitted: fitted, author: author)

                let dx = pEnd.x - pStart.x
                let dy = pEnd.y - pStart.y
                let _ = hypot(dx, dy) > 5

                // Handle selection rectangle end
                if let rect = selectionRect {
                    // Find all objects that intersect with the selection rectangle
                    selectedObjectIDs.removeAll()
                    for obj in objects {
                        if objectIntersects(obj, with: rect) {
                            selectedObjectIDs.insert(obj.id)
                        }
                    }
                    selectionRect = nil
                    selectionDragStart = nil
                }

                // Generate snapshot for blur object if it was modified
                if let sel = selectedObjectID,
                   let idx = objects.firstIndex(where: { $0.id == sel }) {
                    if case .blur(let o) = objects[idx] {
                        generateBlurSnapshot(for: o)
                    }
                }

                // Reset rotation anchors (for Rect)
                rectRotateStartAngle = nil
                rectRotateStartValue = nil
                textRotateStartAngle = nil
                textRotateStartValue = nil
                imageRotateStartAngle = nil
                imageRotateStartValue = nil
                blurRotateStartAngle = nil
                blurRotateStartValue = nil

                dragStartPoint = nil
                pushedDragUndo = false
            }
    }
    
    func badgeGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard allowDraftTick() else { return }
                let pFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let p = fittedToAuthorPoint(pFit, fitted: fitted, author: author)
                
                if dragStartPoint == nil {
                    dragStartPoint = p
                    // If starting on a badge, select it and decide handle (resize vs move)
                    if let idx = objects.lastIndex(where: { obj in
                        switch obj {
                        case .badge(let o): return o.handleHitTest(p) != .none || o.hitTest(p)
                        default: return false
                        }
                    }) {
                        selectedObjectID = objects[idx].id
                        if case .badge(let o) = objects[idx] { activeHandle = o.handleHitTest(p) }
                    } else {
                        selectedObjectID = nil
                        activeHandle = .none
                    }
                } else if
                    let sel = selectedObjectID,
                    let start = dragStartPoint,
                    let idx = objects.firstIndex(where: { $0.id == sel })
                {
                    let delta = CGSize(width: p.x - start.x, height: p.y - start.y)
                    let dragDistance = hypot(delta.width, delta.height)
                    
                    if dragDistance > 0.5 { // any movement begins interaction
                        if !pushedDragUndo { pushUndoSnipshot(); pushedDragUndo = true }
                        switch objects[idx] {
                        case .badge(let o):
                            let clampedP = clampPoint(p, in: author)
                            let updated = (activeHandle == .none) ? o.moved(by: delta) : o.resizing(activeHandle, to: clampedP)
                            let clamped = clampRect(updated.rect, in: author)
                            var u = updated; u.rect = clamped
                            objects[idx] = .badge(u)
                        default:
                            break
                        }
                        dragStartPoint = p
                    }
                }
            }
            .onEnded { value in
                let endFit = CGPoint(x: value.location.x - insetOrigin.x, y: value.location.y - insetOrigin.y)
                let startFit = CGPoint(x: value.startLocation.x - insetOrigin.x, y: value.startLocation.y - insetOrigin.y)
                let pEnd = fittedToAuthorPoint(endFit, fitted: fitted, author: author)
                let pStart = fittedToAuthorPoint(startFit, fitted: fitted, author: author)
                
                let dx = pEnd.x - pStart.x
                let dy = pEnd.y - pStart.y
                let moved = hypot(dx, dy) > 5 // threshold similar to text/pointer
                
                defer { dragStartPoint = nil; pushedDragUndo = false; activeHandle = .none }
                
                // If we interacted with an existing badge (moved/resized), do not create a new one
                if moved, selectedObjectID != nil {
                    return
                }
                
                // If we started on a badge but didn’t move enough, just select it and return
                if let sel = selectedObjectID, let idx = objects.firstIndex(where: { $0.id == sel }) {
                    if case .badge(let o) = objects[idx], o.hitTest(pStart) || o.handleHitTest(pStart) != .none {
                        return
                    }
                }
                
                // Otherwise, create a new badge at the click location
                let diameter: CGFloat = 32
                let rect = CGRect(x: max(0, pEnd.x - diameter/2),
                                  y: max(0, pEnd.y - diameter/2),
                                  width: diameter,
                                  height: diameter)
                let rectClamped = clampRect(rect, in: author)
                badgeCount &+= 1
                let newObj = BadgeObject(rect: rectClamped, number: badgeCount, fillColor: badgeColor, textColor: .white)
                pushUndoSnipshot()
                objects.append(.badge(newObj))
                if objectSpaceSize == nil { objectSpaceSize = author }
                selectedObjectID = newObj.id
            }
    }
    
    @inline(__always)
    func fittedToAuthorPoint(_ p: CGPoint, fitted: CGSize, author: CGSize) -> CGPoint {
        let sx = author.width  / max(1, fitted.width)
        let sy = author.height / max(1, fitted.height)
        return CGPoint(x: p.x * sx, y: p.y * sy)
    }
    
    @inline(__always)
    func normalizeRect(_ r: CGRect) -> CGRect {
        CGRect(x: min(r.minX, r.maxX),
               y: min(r.minY, r.maxY),
               width: abs(r.width),
               height: abs(r.height))
    }
    
    
    func cropGesture(insetOrigin: CGPoint, fitted: CGSize, author: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // 1) Pointer in fitted space (subtract centering inset)
                let locFitted = CGPoint(
                    x: value.location.x - insetOrigin.x,
                    y: value.location.y - insetOrigin.y
                )
                // 2) Clamp to the visible fitted image
                let clampedFitted = CGPoint(
                    x: min(max(0, locFitted.x), fitted.width),
                    y: min(max(0, locFitted.y), fitted.height)
                )
                // 3) Convert to author/object space where overlay lives
                let locAuthor = fittedToAuthorPoint(clampedFitted, fitted: fitted, author: author)
                
                if cropDragStart == nil {
                    // First event of this drag
                    cropDragStart = locAuthor
                    // If we already have a rect, check for handle resize
                    if let existing = cropRect {
                        let handle = cropHandleHitTest(existing, at: locAuthor)
                        if handle != .none {
                            cropHandle = handle
                            cropOriginalRect = existing
                            return
                        }
                    }
                }
                
                if cropHandle != .none, let original = cropOriginalRect {
                    // Resizing existing rect
                    cropRect = normalizeRect(resizeRect(original, handle: cropHandle, to: locAuthor))
                    cropDraftRect = nil
                } else if let start = cropDragStart {
                    // Drafting a new rect during drag
                    cropDraftRect = normalizeRect(CGRect(
                        x: min(start.x, locAuthor.x),
                        y: min(start.y, locAuthor.y),
                        width: abs(locAuthor.x - start.x),
                        height: abs(locAuthor.y - start.y)
                    ))
                }
            }
            .onEnded { _ in
                defer {
                    cropDragStart = nil
                    cropOriginalRect = nil
                    cropHandle = .none
                }
                
                if cropHandle != .none, let updated = cropRect {
                    // Finished a resize — keep normalized
                    cropRect = normalizeRect(updated)
                    cropDraftRect = nil
                    return
                }
                
                if let draft = cropDraftRect {
                    // Commit new rect
                    cropRect = normalizeRect(draft)
                    cropDraftRect = nil
                }
            }
    }
    
    // MARK: - Editing Tools
    
    func selectionHandlesForLine(_ o: LineObject) -> some View {
        ZStack {
            Circle().stroke(.blue, lineWidth: 1)
                .background(Circle().fill(.white))
                .frame(width: 12, height: 12)
                .position(o.start)
            
            Circle().stroke(.blue, lineWidth: 1)
                .background(Circle().fill(.white))
                .frame(width: 12, height: 12)
                .position(o.end)
        }
    }
    
    @inline(__always)
    func rotatePoint(_ p: CGPoint, around c: CGPoint, by angle: CGFloat) -> CGPoint {
        let s = sin(angle), co = cos(angle)
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * co - dy * s,
                       y: c.y + dx * s + dy * co)
    }

    func selectionHandlesForRect(_ o: RectObject) -> some View {
        let rotateOffset: CGFloat = 20
        let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

        // Raw unrotated positions
        let rawPts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        let rawRotate = CGPoint(x: o.rect.maxX + rotateOffset, y: o.rect.minY - rotateOffset)

        // Rotate positions to match the rotated rectangle
        let pts = rawPts.map { rotatePoint($0, around: c, by: o.rotation) }
        let rotatePos = rotatePoint(rawRotate, around: c, by: o.rotation)

        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.blue)
                .background(Circle().fill(.white).frame(width: 16, height: 16))
                .position(rotatePos)
        }
    }

    func selectionHandlesForBlur(_ o: BlurRectObject) -> some View {
        let rotateOffset: CGFloat = 20
        let c = CGPoint(x: o.rect.midX, y: o.rect.midY)

        // Raw unrotated positions
        let rawPts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        let rawRotate = CGPoint(x: o.rect.maxX + rotateOffset, y: o.rect.minY - rotateOffset)

        // Rotate positions to match the rotated rectangle
        let pts = rawPts.map { rotatePoint($0, around: c, by: o.rotation) }
        let rotatePos = rotatePoint(rawRotate, around: c, by: o.rotation)

        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.blue)
                .background(Circle().fill(.white).frame(width: 16, height: 16))
                .position(rotatePos)
        }
    }
    
    func selectionHandlesForOval(_ o: OvalObject) -> some View {
        let pts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
        }
    }
    
    func selectionHandlesForText(_ o: TextObject) -> some View {
        let rotateOffset: CGFloat = 20
        let c = CGPoint(x: o.rect.midX, y: o.rect.midY)
        
        // Raw unrotated positions
        let rawPts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        let rawRotate = CGPoint(x: o.rect.maxX + rotateOffset, y: o.rect.minY - rotateOffset)
        
        // Rotate positions to match the rotated text box
        let pts = rawPts.map { rotatePoint($0, around: c, by: o.rotation) }
        let rotatePos = rotatePoint(rawRotate, around: c, by: o.rotation)
        
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
            
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.blue)
                .background(Circle().fill(.white).frame(width: 16, height: 16))
                .position(rotatePos)
            
            // TextEditor for focused text (also needs to be in scaled context with rotation)
            if focusedTextID == o.id {
                TextEditor(text: Binding(
                    get: { o.text },
                    set: { newVal in
                        if let idx = objects.firstIndex(where: { $0.id == o.id }) {
                            if case .text(var t) = objects[idx] {
                                t.text = newVal
                                objects[idx] = .text(t)
                            }
                        }
                    }
                ))
                .font(.system(size: o.fontSize))
                .foregroundStyle(Color(nsColor: o.textColor))
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .scrollContentBackground(.hidden)
                .frame(width: o.rect.width, height: o.rect.height, alignment: .topLeading)
                .background(o.bgEnabled ? Color(nsColor: o.bgColor) : Color.clear)
                .rotationEffect(Angle(radians: o.rotation))
                .position(x: o.rect.midX, y: o.rect.midY)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.blue.opacity(0.6), lineWidth: 1)
                        .rotationEffect(Angle(radians: o.rotation))
                )
                .contentShape(Rectangle())
                .focused($isTextEditorFocused)
                .onAppear {
                    DispatchQueue.main.async {
                        isTextEditorFocused = true
                    }
                }
                .onChange(of: focusedTextID) { _,newValue in
                    isTextEditorFocused = (newValue == o.id)
                }
            }
        }
    }
    
    
    func selectionHandlesForBadge(_ o: BadgeObject) -> some View {
        let pts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
        }
    }
    
    func selectionHandlesForHighlight(_ o: HighlightObject) -> some View {
        let pts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
        }
    }
    
    func selectionHandlesForImage(_ o: PastedImageObject) -> some View {
        let rotateOffset: CGFloat = 20
        let c = CGPoint(x: o.rect.midX, y: o.rect.midY)
        
        // Raw unrotated positions
        let rawPts = [
            CGPoint(x: o.rect.minX, y: o.rect.minY),
            CGPoint(x: o.rect.maxX, y: o.rect.minY),
            CGPoint(x: o.rect.minX, y: o.rect.maxY),
            CGPoint(x: o.rect.maxX, y: o.rect.maxY)
        ]
        let rawRotate = CGPoint(x: o.rect.maxX + rotateOffset, y: o.rect.minY - rotateOffset)
        
        // Rotate positions to match the rotated image
        let pts = rawPts.map { rotatePoint($0, around: c, by: o.rotation) }
        let rotatePos = rotatePoint(rawRotate, around: c, by: o.rotation)
        
        return ZStack {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(.blue, lineWidth: 1)
                    .background(Circle().fill(.white))
                    .frame(width: 12, height: 12)
                    .position(pt)
            }
            
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.blue)
                .background(Circle().fill(.white).frame(width: 16, height: 16))
                .position(rotatePos)
        }
    }
    
    // Arrow Tool
    func arrowHeadPath(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> Path {
        var path = Path()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return path }
        
        // Direction unit vector from start -> end
        let ux = dx / len
        let uy = dy / len
        
        // Bigger head: scale with stroke width, but cap by a fraction of the line length
        let desired = max(16, lineWidth * 6.0)
        let capped  = min(len * 0.35, 280)
        let headLength = min(desired, capped)
        let headWidth  = headLength * 0.90
        
        let tip = end
        let baseX = tip.x - headLength * ux
        let baseY = tip.y - headLength * uy
        
        let px = -uy, py = ux // perpendicular
        let left  = CGPoint(x: baseX + (headWidth * 0.5) * px, y: baseY + (headWidth * 0.5) * py)
        let right = CGPoint(x: baseX - (headWidth * 0.5) * px, y: baseY - (headWidth * 0.5) * py)
        
        path.move(to: tip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        return path
    }
    
    
    func flattenAndSaveInPlace() {
        guard let img = currentImage else { return }
        if objectSpaceSize == nil { objectSpaceSize = lastFittedSize ?? img.size }
        pushUndoSnipshot()
        if let flattened = rasterize(base: img, objects: objects) {
            objects.removeAll()
            if let url = selectedSnipURL {
                // Write the flattened image back to the same file, preserving creation date
                if ImageSaver.writeImage(flattened, to: url, format: preferredSaveFormat.rawValue, quality: saveQuality, preserveAttributes: true) {
                    reloadCurrentImage()
                    thumbnailRefreshTrigger = UUID()
                }
            } else {
                saveAsCurrent()
            }
        }
    }
    
    func flattenAndSaveAs() {
        guard let img = currentImage else { return }
        if objectSpaceSize == nil { objectSpaceSize = lastFittedSize ?? img.size }
        pushUndoSnipshot()
        if let flattened = rasterize(base: img, objects: objects) {
            objects.removeAll()
            exportImage = flattened
            showingFileExporter = true
        }
    }
    
    func rasterize(base: NSImage, objects: [Drawable]) -> NSImage? {
        // Keep logical canvas in points (matches editor), but render into a bitmap using the base image's backing pixels.
        let imgSize = base.size // points
        
        // Determine backing pixel dimensions (prefer CGImage; else largest bitmap rep; else fall back to points)
        let pixelDims: (w: Int, h: Int) = {
            if let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return (cg.width, cg.height)
            }
            if let best = base.representations
                .compactMap({ $0 as? NSBitmapImageRep })
                .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
                return (best.pixelsWide, best.pixelsHigh)
            }
            return (Int(round(imgSize.width)), Int(round(imgSize.height)))
        }()
        
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, pixelDims.w),
            pixelsHigh: max(1, pixelDims.h),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        
        // Critical: set logical size (points). Drawing uses points; pixels are handled by the rep's pixel size.
        rep.size = imgSize
        
        let composed = NSImage(size: imgSize)
        composed.addRepresentation(rep)
        
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            
            // Render overlay objects. These utilities assume `image` is in points, which matches `imgSize`.
            let fitted = objectSpaceSize ?? lastFittedSize ?? imgSize

            // Draw the base image to fill the logical canvas
            base.draw(in: CGRect(origin: .zero, size: imgSize))
            let scaleX = imgSize.width / max(1, fitted.width)
            let scaleY = imgSize.height / max(1, fitted.height)
            let scaleW = (scaleX + scaleY) / 2

            // Collect blur objects for second pass
            var blurObjects: [(BlurRectObject, Int)] = []

            for (index, obj) in objects.enumerated() {
                // Skip blur objects in first pass
                if case .blur(let o) = obj {
                    blurObjects.append((o, index))
                    continue
                }

                switch obj {
                case .line(let o):
                    let s = uiToImagePoint(o.start, fitted: fitted, image: imgSize)
                    let e = uiToImagePoint(o.end,   fitted: fitted, image: imgSize)
                    let widthScaled = o.width * scaleW
                    o.color.setStroke(); o.color.setFill()
                    let path = NSBezierPath()
                    path.lineWidth = widthScaled
                    path.lineCapStyle = o.arrow ? .butt : .round
                    path.move(to: s)
                    
                    // If arrow, shorten the line so it doesn't extend under the arrow head
                    if o.arrow {
                        let dx = e.x - s.x, dy = e.y - s.y
                        let len = max(1, hypot(dx, dy))
                        let ux = dx / len, uy = dy / len
                        
                        let desired = max(16, widthScaled * 6.0)
                        let capped  = min(len * 0.35, 280)
                        let headLength = min(desired, capped)
                        
                        // Stop the line at the base of the arrow head
                        let lineEnd = CGPoint(x: e.x - ux * headLength, y: e.y - uy * headLength)
                        path.line(to: lineEnd)
                    } else {
                        path.line(to: e)
                    }
                    
                    path.stroke()
                    
                    if o.arrow {
                        let dx = e.x - s.x, dy = e.y - s.y
                        let len = max(1, hypot(dx, dy))
                        let ux = dx / len, uy = dy / len
                        
                        let desired = max(16, widthScaled * 6.0)
                        let capped  = min(len * 0.35, 280)
                        let headLength = min(desired, capped)
                        let headWidth  = headLength * 0.90
                        
                        // Arrow head at the exact end point
                        let bx = e.x - ux * headLength
                        let by = e.y - uy * headLength
                        let px = -uy, py = ux
                        let p1 = CGPoint(x: bx + (headWidth * 0.5) * px, y: by + (headWidth * 0.5) * py)
                        let p2 = CGPoint(x: bx - (headWidth * 0.5) * px, y: by - (headWidth * 0.5) * py)
                        
                        let tri = NSBezierPath()
                        tri.move(to: e)  // Tip at exact end point
                        tri.line(to: p1)
                        tri.line(to: p2)
                        tri.close()
                        tri.fill()
                    }
                case .rect(let o):
                    o.color.setStroke()
                    
                    if o.rotation != 0 {
                        NSGraphicsContext.current?.saveGraphicsState()
                        
                        // Apply rotation in UI space first, then transform to image space
                        let uiCenter = CGPoint(x: o.rect.midX, y: o.rect.midY)
                        
                        // Create the four corners of the rectangle in UI space
                        let corners = [
                            CGPoint(x: o.rect.minX, y: o.rect.minY),
                            CGPoint(x: o.rect.maxX, y: o.rect.minY),
                            CGPoint(x: o.rect.maxX, y: o.rect.maxY),
                            CGPoint(x: o.rect.minX, y: o.rect.maxY)
                        ]
                        
                        // Rotate corners around center in UI space
                        let rotatedCorners = corners.map { corner in
                            let dx = corner.x - uiCenter.x
                            let dy = corner.y - uiCenter.y
                            let cos = Foundation.cos(o.rotation)
                            let sin = Foundation.sin(o.rotation)
                            return CGPoint(
                                x: uiCenter.x + dx * cos - dy * sin,
                                y: uiCenter.y + dx * sin + dy * cos
                            )
                        }
                        
                        // Transform each rotated corner to image space
                        let imageCorners = rotatedCorners.map {
                            uiToImagePoint($0, fitted: fitted, image: imgSize)
                        }
                        
                        // Draw the rotated rectangle as a polygon
                        let path = NSBezierPath()
                        path.move(to: imageCorners[0])
                        for i in 1..<imageCorners.count {
                            path.line(to: imageCorners[i])
                        }
                        path.close()
                        path.lineWidth = o.width * scaleW
                        path.stroke()
                        
                        NSGraphicsContext.current?.restoreGraphicsState()
                    } else {
                        let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                        let path = NSBezierPath(rect: r)
                        path.lineWidth = o.width * scaleW
                        path.stroke()
                    }
                case .oval(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    o.color.setStroke()
                    let path = NSBezierPath(ovalIn: r)
                    path.lineWidth = o.width * scaleW
                    path.stroke()
                case .text(let o):
                    // For rotated text, we need to work entirely in UI space first, then convert to image space
                    if o.rotation != 0 {
                        NSGraphicsContext.current?.saveGraphicsState()
                        
                        // 1. Get the UI space rect and center
                        let uiRect = o.rect
                        let uiCenter = CGPoint(x: uiRect.midX, y: uiRect.midY)
                        
                        // 2. Convert center to image space
                        let imageCenter = uiToImagePoint(uiCenter, fitted: fitted, image: imgSize)
                        
                        // 3. Convert size to image space (no Y-flip for size)
                        let imageSize = CGSize(
                            width: uiRect.width * (imgSize.width / max(1, fitted.width)),
                            height: uiRect.height * (imgSize.height / max(1, fitted.height))
                        )
                        
                        // 4. Create image rect centered at the converted center
                        let imageRect = CGRect(
                            x: imageCenter.x - imageSize.width / 2,
                            y: imageCenter.y - imageSize.height / 2,
                            width: imageSize.width,
                            height: imageSize.height
                        )
                        
                        // 5. Apply rotation in image space around the image center
                        // Note: Negate the rotation because image Y is flipped from UI Y
                        let transform = NSAffineTransform()
                        transform.translateX(by: imageCenter.x, yBy: imageCenter.y)
                        transform.rotate(byRadians: -o.rotation)  // Negate rotation for flipped coordinate system
                        transform.translateX(by: -imageCenter.x, yBy: -imageCenter.y)
                        transform.concat()
                        
                        // 6. Draw background if enabled
                        if o.bgEnabled {
                            let paddingScaled = 4 * scaleW
                            let bgRect = imageRect.insetBy(dx: -paddingScaled, dy: -paddingScaled)
                            let bg = NSBezierPath(rect: bgRect)
                            o.bgColor.setFill()
                            bg.fill()
                        }
                        
                        // 7. Draw text
                        let para = NSMutableParagraphStyle()
                        para.alignment = .left
                        para.lineBreakMode = .byWordWrapping
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: o.fontSize * scaleW),
                            .foregroundColor: o.textColor,
                            .paragraphStyle: para
                        ]
                        
                        NSString(string: o.text).draw(in: imageRect, withAttributes: attrs)
                        
                        NSGraphicsContext.current?.restoreGraphicsState()
                    } else {
                        // Non-rotated text - use existing logic
                        let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                        let paddingScaled = 4 * scaleW
                        
                        // Draw background with proper padding to match SwiftUI rendering
                        if o.bgEnabled {
                            let bgRect = r.insetBy(dx: -paddingScaled, dy: -paddingScaled)
                            let bg = NSBezierPath(rect: bgRect)
                            o.bgColor.setFill()
                            bg.fill()
                        }
                        
                        // Draw text
                        let para = NSMutableParagraphStyle()
                        para.alignment = .left
                        para.lineBreakMode = .byWordWrapping
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: o.fontSize * scaleW),
                            .foregroundColor: o.textColor,
                            .paragraphStyle: para
                        ]
                        
                        NSString(string: o.text).draw(in: r, withAttributes: attrs)
                    }
                case .badge(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    
                    // Draw the circle background
                    let circle = NSBezierPath(ovalIn: r)
                    o.fillColor.setFill()
                    circle.fill()
                    
                    // Calculate font size
                    let fontSize = min(r.width, r.height) * 0.6
                    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
                    
                    // Create attributed string
                    let numberString = "\(o.number)"
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: o.textColor
                    ]
                    let attributedString = NSAttributedString(string: numberString, attributes: attrs)
                    
                    // Calculate text size and center it manually
                    let textSize = attributedString.size()
                    let textRect = CGRect(
                        x: r.midX - textSize.width / 2,
                        y: r.midY - textSize.height / 2,
                        width: textSize.width,
                        height: textSize.height
                    )
                    
                    // Draw the text at the calculated position
                    attributedString.draw(in: textRect)
                case .highlight(let o):
                    let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                    o.color.setFill(); NSBezierPath(rect: r).fill()
                case .image(let o):
                    if o.rotation != 0 {
                        NSGraphicsContext.current?.saveGraphicsState()

                        // 1. Get the UI space rect and center
                        let uiRect = o.rect
                        let uiCenter = CGPoint(x: uiRect.midX, y: uiRect.midY)

                        // 2. Convert center to image space
                        let imageCenter = uiToImagePoint(uiCenter, fitted: fitted, image: imgSize)

                        // 3. Convert size to image space (no Y-flip for size)
                        let imageSize = CGSize(
                            width: uiRect.width * (imgSize.width / max(1, fitted.width)),
                            height: uiRect.height * (imgSize.height / max(1, fitted.height))
                        )

                        // 4. Create image rect centered at the converted center
                        let imageRect = CGRect(
                            x: imageCenter.x - imageSize.width / 2,
                            y: imageCenter.y - imageSize.height / 2,
                            width: imageSize.width,
                            height: imageSize.height
                        )

                        // 5. Apply rotation in image space around the image center
                        // Note: Negate the rotation because image Y is flipped from UI Y
                        let transform = NSAffineTransform()
                        transform.translateX(by: imageCenter.x, yBy: imageCenter.y)
                        transform.rotate(byRadians: -o.rotation)  // Negate rotation for flipped coordinate system
                        transform.translateX(by: -imageCenter.x, yBy: -imageCenter.y)
                        transform.concat()

                        // 6. Draw the image
                        o.image.draw(in: imageRect)

                        NSGraphicsContext.current?.restoreGraphicsState()
                    } else {
                        // Non-rotated image - use existing logic
                        let r = uiRectToImageRect(o.rect, fitted: fitted, image: imgSize)
                        o.image.draw(in: r)
                    }
                case .blur:
                    // Blur objects are handled in second pass - see line 4172
                    break
                }
            }

            // Second pass: Apply blur effects
            // We do this after all other objects are drawn so the blur can affect them

            // Flush graphics to ensure all drawing is committed to rep
            NSGraphicsContext.current?.flushGraphics()

            // Use the rep's CGImage directly - it has all the drawing we just did
            if let currentCGImage = rep.cgImage {
                print("Processing blur objects, count: \(blurObjects.count)")

                // Create a new graphics context focused on rep for blur drawing
                let repContext = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = repContext

                for (blurObj, _) in blurObjects {
                    // Blur rects are in author space, use same conversion as crop
                    let (pixelBL, _) = authorRectToPixelBL(
                        authorRect: blurObj.rect,
                        baseImage: base,
                        selectedImageSize: selectedImageSize,
                        imageDisplayMode: imageDisplayMode,
                        currentGeometrySize: currentGeometrySize,
                        objectSpaceSize: objectSpaceSize
                    )

                    // Convert BL to TL for CGImage cropping (CGImage uses top-left origin)
                    let pixelTL = CGRect(
                        x: pixelBL.origin.x,
                        y: CGFloat(currentCGImage.height) - pixelBL.origin.y - pixelBL.height,
                        width: pixelBL.width,
                        height: pixelBL.height
                    )

                    // Clamp to image bounds
                    let rPixels = CGRect(
                        x: max(0, pixelTL.origin.x).rounded(.down),
                        y: max(0, pixelTL.origin.y).rounded(.down),
                        width: min(CGFloat(currentCGImage.width) - max(0, pixelTL.origin.x), pixelTL.width).rounded(.down),
                        height: min(CGFloat(currentCGImage.height) - max(0, pixelTL.origin.y), pixelTL.height).rounded(.down)
                    )

                    // Convert back to BL points for drawing (NSImage uses bottom-left)
                    let pxToPointsX = imgSize.width / CGFloat(currentCGImage.width)
                    let pxToPointsY = imgSize.height / CGFloat(currentCGImage.height)
                    let rTLPoints = CGRect(
                        x: rPixels.origin.x * pxToPointsX,
                        y: rPixels.origin.y * pxToPointsY,
                        width: rPixels.width * pxToPointsX,
                        height: rPixels.height * pxToPointsY
                    )
                    let r = CGRect(
                        x: rTLPoints.origin.x,
                        y: imgSize.height - rTLPoints.origin.y - rTLPoints.height,
                        width: rTLPoints.width,
                        height: rTLPoints.height
                    )

                    // Don't scale the blur radius - use it directly as pixel block size
                    let pixelSize = max(1, blurObj.blurRadius)

                    print("UI rect: \(blurObj.rect)")
                    print("Fitted: \(fitted), ImgSize (points): \(imgSize)")
                    print("Rect in points (bottom-left from uiRectToImageRect): \(r)")
                    print("Rect in pixels (bottom-left for CGImage): \(rPixels)")
                    print("CGImage size: \(currentCGImage.width)x\(currentCGImage.height)")

                    // Manually create pixelation by downscaling and upscaling
                    // Crop from CGImage using pixel coordinates, draw back using point coordinates

                    // Use a simpler approach: downsample and upsample with proper dimensions
                    if let croppedRegion = currentCGImage.cropping(to: rPixels) {
                        print("Cropped region from \(rPixels), size: \(croppedRegion.width)x\(croppedRegion.height)")



                        // Calculate downsampled dimensions
                        let downsampledWidth = max(1, Int(CGFloat(croppedRegion.width) / pixelSize))
                        let downsampledHeight = max(1, Int(CGFloat(croppedRegion.height) / pixelSize))

                        print("Downsampling to: \(downsampledWidth)x\(downsampledHeight)")

                        // Create a small context for downsampling
                        let colorSpace = CGColorSpaceCreateDeviceRGB()
                        if let downsampleContext = CGContext(
                            data: nil,
                            width: downsampledWidth,
                            height: downsampledHeight,
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        ) {
                            // Use high quality interpolation for downsampling to get average color
                            downsampleContext.interpolationQuality = .high
                            downsampleContext.draw(croppedRegion, in: CGRect(x: 0, y: 0, width: downsampledWidth, height: downsampledHeight))

                            if let downsampledImage = downsampleContext.makeImage() {
                                // Now create a full-size context to draw the pixelated result
                                if let upsampleContext = CGContext(
                                    data: nil,
                                    width: croppedRegion.width,
                                    height: croppedRegion.height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: 0,
                                    space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                ) {
                                    // Use nearest neighbor (no interpolation) when upsampling for blocky effect
                                    upsampleContext.interpolationQuality = .none
                                    upsampleContext.draw(downsampledImage, in: CGRect(x: 0, y: 0, width: croppedRegion.width, height: croppedRegion.height))

                                    if let pixelatedImage = upsampleContext.makeImage() {
                                        NSGraphicsContext.current?.saveGraphicsState()

                                        if NSGraphicsContext.current?.cgContext != nil {
                                            // Use r (bottom-left coords) for drawing, same as rectangles/lines
                                            let pixelatedNSImage = NSImage(cgImage: pixelatedImage, size: r.size)

                                            if blurObj.rotation != 0 {
                                                NSGraphicsContext.current?.saveGraphicsState()

                                                let imageCenter = CGPoint(x: r.midX, y: r.midY)
                                                let clipPath = NSBezierPath(rect: r)
                                                let transform = NSAffineTransform()
                                                transform.translateX(by: imageCenter.x, yBy: imageCenter.y)
                                                transform.rotate(byRadians: -blurObj.rotation)
                                                transform.translateX(by: -imageCenter.x, yBy: -imageCenter.y)
                                                clipPath.transform(using: transform as AffineTransform)
                                                clipPath.addClip()

                                                pixelatedNSImage.draw(in: r)
                                                NSGraphicsContext.current?.restoreGraphicsState()
                                            } else {
                                                pixelatedNSImage.draw(in: r)
                                            }
                                        }

                                        NSGraphicsContext.current?.restoreGraphicsState()
                                        print("Drew pixelated region at \(r)")
                                    } else {
                                        print("Failed to create upsampled image")
                                    }
                                } else {
                                    print("Failed to create upsample context")
                                }
                            } else {
                                print("Failed to create downsampled image")
                            }
                        } else {
                            print("Failed to create downsample context")
                        }
                    } else {
                        print("Failed to crop region for pixelation")
                    }
                }

                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return composed
    }
    
    func deleteSelectedObject() {
        // If the inline TextEditor has keyboard focus, do NOT delete the text object.
        // This lets the Delete/Backspace key edit text content instead of removing the box.
        if isTextEditorFocused {
            return
        }
        guard let sel = selectedObjectID, let idx = objects.firstIndex(where: { $0.id == sel }) else { return }
        pushUndoSnipshot()

        // Clear blur snapshot if deleting a blur object
        if case .blur = objects[idx] {
            blurSnapshots[sel] = nil
        }

        objects.remove(at: idx)
        selectedObjectID = nil
        activeHandle = .none
    }

    func deleteMultipleSelectedObjects() {
        if isTextEditorFocused {
            return
        }
        guard !selectedObjectIDs.isEmpty else { return }
        pushUndoSnipshot()

        // Clear blur snapshots for any blur objects being deleted
        for objID in selectedObjectIDs {
            if let idx = objects.firstIndex(where: { $0.id == objID }) {
                if case .blur = objects[idx] {
                    blurSnapshots[objID] = nil
                }
            }
        }

        // Remove all selected objects
        objects.removeAll { obj in
            selectedObjectIDs.contains(obj.id)
        }

        // Clear selection
        selectedObjectIDs.removeAll()
        selectedObjectID = nil
        activeHandle = .none
    }


}
