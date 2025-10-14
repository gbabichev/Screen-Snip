import SwiftUI

extension ContentView {
    func clampPoint(_ p: CGPoint, in fitted: CGSize) -> CGPoint {
        CGPoint(x: min(max(0, p.x), fitted.width),
                y: min(max(0, p.y), fitted.height))
    }
    
    /// Clamps a non-rotated rect to stay within canvas bounds
    func clampRect(_ r: CGRect, in fitted: CGSize) -> CGRect {
        var rect = r

        // Clamp the rect to stay within canvas bounds
        // For moving/positioning: keep the object's size and just adjust position
        // For resizing: the size might exceed bounds, so trim it

        // If origin is negative (object moved past top/left edge)
        if rect.origin.x < 0 {
            // If the size extends beyond the opposite edge, we're resizing - trim the size
            if rect.maxX > fitted.width {
                rect.size.width = fitted.width
            }
            rect.origin.x = 0
        }
        if rect.origin.y < 0 {
            // If the size extends beyond the opposite edge, we're resizing - trim the size
            if rect.maxY > fitted.height {
                rect.size.height = fitted.height
            }
            rect.origin.y = 0
        }

        // Clamp position to keep object within bounds (for moving)
        if rect.maxX > fitted.width {
            rect.origin.x = max(0, fitted.width - rect.size.width)
        }
        if rect.maxY > fitted.height {
            rect.origin.y = max(0, fitted.height - rect.size.height)
        }

        // If object is larger than canvas, shrink it
        if rect.size.width > fitted.width {
            rect.size.width = fitted.width
            rect.origin.x = 0
        }
        if rect.size.height > fitted.height {
            rect.size.height = fitted.height
            rect.origin.y = 0
        }

        // Ensure minimum size
        rect.size.width = max(2, rect.size.width)
        rect.size.height = max(2, rect.size.height)

        return rect
    }

    /// Checks if a rotated rect's axis-aligned bounding box fits within canvas bounds
    /// Returns true if the entire AABB is within bounds
    func rotatedRectFitsInBounds(_ rect: CGRect, rotation: CGFloat, in fitted: CGSize) -> Bool {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]

        let s = sin(rotation), co = cos(rotation)
        let rotatedCorners = corners.map { corner -> CGPoint in
            let dx = corner.x - center.x
            let dy = corner.y - center.y
            return CGPoint(
                x: center.x + dx * co - dy * s,
                y: center.y + dx * s + dy * co
            )
        }

        let minX = rotatedCorners.map { $0.x }.min() ?? center.x
        let maxX = rotatedCorners.map { $0.x }.max() ?? center.x
        let minY = rotatedCorners.map { $0.y }.min() ?? center.y
        let maxY = rotatedCorners.map { $0.y }.max() ?? center.y

        return minX >= 0 && maxX <= fitted.width && minY >= 0 && maxY <= fitted.height
    }

    func adjustedDeltaComponent(desired: CGFloat, current: CGFloat, allowed: CGFloat) -> CGFloat {
        guard desired != 0 else { return 0 }
        if desired > 0 {
            return min(current, allowed)
        } else {
            return max(current, allowed)
        }
    }

    /// Calculates the maximum allowed delta for moving a non-rotated rect without going off-canvas
    /// Returns a clamped delta that keeps the rect within bounds
    func clampedDeltaForRect(_ rect: CGRect, delta: CGSize, in fitted: CGSize) -> CGSize {
        var clampedDelta = delta

        // Calculate proposed position after applying delta
        let newMinX = rect.minX + delta.width
        let newMaxX = rect.maxX + delta.width
        let newMinY = rect.minY + delta.height
        let newMaxY = rect.maxY + delta.height

        // Clamp X
        if newMinX < 0 {
            clampedDelta.width = delta.width - newMinX
        } else if newMaxX > fitted.width {
            clampedDelta.width = delta.width - (newMaxX - fitted.width)
        }

        // Clamp Y
        if newMinY < 0 {
            clampedDelta.height = delta.height - newMinY
        } else if newMaxY > fitted.height {
            clampedDelta.height = delta.height - (newMaxY - fitted.height)
        }

        return clampedDelta
    }

    func clampedDeltaForLine(_ line: LineObject, delta: CGSize, in fitted: CGSize) -> CGSize {
        var clampedDelta = delta

        let minX = min(line.start.x, line.end.x)
        let maxX = max(line.start.x, line.end.x)
        if delta.width < 0 {
            clampedDelta.width = max(delta.width, -minX)
        } else if delta.width > 0 {
            clampedDelta.width = min(delta.width, fitted.width - maxX)
        }

        let minY = min(line.start.y, line.end.y)
        let maxY = max(line.start.y, line.end.y)
        if delta.height < 0 {
            clampedDelta.height = max(delta.height, -minY)
        } else if delta.height > 0 {
            clampedDelta.height = min(delta.height, fitted.height - maxY)
        }

        return clampedDelta
    }

    /// Calculates the maximum allowed delta for moving a rotated rect without going off-canvas
    /// Returns a clamped delta that keeps the rotated rect within bounds
    func clampedDeltaForRotatedRect(_ rect: CGRect, rotation: CGFloat, delta: CGSize, in fitted: CGSize) -> CGSize {
        print("DEBUG clampedDeltaForRotatedRect: Called with rect=\(rect), rotation=\(rotation), delta=\(delta), fitted=\(fitted)")
        // Calculate the AABB of the rotated rect at its current position
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]

        let s = sin(rotation), co = cos(rotation)
        let rotatedCorners = corners.map { corner -> CGPoint in
            let dx = corner.x - center.x
            let dy = corner.y - center.y
            return CGPoint(
                x: center.x + dx * co - dy * s,
                y: center.y + dx * s + dy * co
            )
        }

        let minX = rotatedCorners.map { $0.x }.min() ?? center.x
        let maxX = rotatedCorners.map { $0.x }.max() ?? center.x
        let minY = rotatedCorners.map { $0.y }.min() ?? center.y
        let maxY = rotatedCorners.map { $0.y }.max() ?? center.y

        // Calculate the proposed new AABB after applying delta
        let newMinX = minX + delta.width
        let newMaxX = maxX + delta.width
        let newMinY = minY + delta.height
        let newMaxY = maxY + delta.height

        // Clamp the delta to keep AABB within bounds
        var clampedDelta = delta

        if newMinX < 0 {
            clampedDelta.width = delta.width - newMinX  // Reduce delta to stay in bounds
        } else if newMaxX > fitted.width {
            clampedDelta.width = delta.width - (newMaxX - fitted.width)
        }

        if newMinY < 0 {
            clampedDelta.height = delta.height - newMinY
        } else if newMaxY > fitted.height {
            clampedDelta.height = delta.height - (newMaxY - fitted.height)
        }

        print("DEBUG clampedDeltaForRotatedRect: Returning clampedDelta=\(clampedDelta)")
        return clampedDelta
    }

    /// Clamps a rotated rect to stay within canvas bounds by adjusting its position
    /// Returns the new rect with clamped center position
    func clampRotatedRect(_ r: CGRect, rotation: CGFloat, in fitted: CGSize) -> CGRect {
        // Calculate the axis-aligned bounding box of the rotated rect
        let center = CGPoint(x: r.midX, y: r.midY)
        let corners = [
            CGPoint(x: r.minX, y: r.minY),
            CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.maxY),
            CGPoint(x: r.maxX, y: r.maxY)
        ]

        // Rotate corners around the center
        let s = sin(rotation), co = cos(rotation)
        let rotatedCorners = corners.map { corner -> CGPoint in
            let dx = corner.x - center.x
            let dy = corner.y - center.y
            return CGPoint(
                x: center.x + dx * co - dy * s,
                y: center.y + dx * s + dy * co
            )
        }

        // Find the AABB of rotated corners
        let minX = rotatedCorners.map { $0.x }.min() ?? center.x
        let maxX = rotatedCorners.map { $0.x }.max() ?? center.x
        let minY = rotatedCorners.map { $0.y }.min() ?? center.y
        let maxY = rotatedCorners.map { $0.y }.max() ?? center.y

        // Calculate how much the AABB extends beyond canvas bounds
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0

        if minX < 0 {
            offsetX = -minX
        } else if maxX > fitted.width {
            offsetX = fitted.width - maxX
        }

        if minY < 0 {
            offsetY = -minY
        } else if maxY > fitted.height {
            offsetY = fitted.height - maxY
        }

        // Apply the offset to the rect's center
        var result = r
        result.origin.x += offsetX
        result.origin.y += offsetY

        return result
    }

    func objectIntersects(_ obj: Drawable, with selectionRect: CGRect) -> Bool {
        switch obj {
        case .line(let o):
            // Check if line's bounding box intersects with selection rect
            let minX = min(o.start.x, o.end.x)
            let maxX = max(o.start.x, o.end.x)
            let minY = min(o.start.y, o.end.y)
            let maxY = max(o.start.y, o.end.y)
            let lineBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            return selectionRect.intersects(lineBounds)
        case .rect(let o):
            return selectionRect.intersects(o.rect)
        case .oval(let o):
            return selectionRect.intersects(o.rect)
        case .text(let o):
            return selectionRect.intersects(o.rect)
        case .badge(let o):
            return selectionRect.intersects(o.rect)
        case .highlight(let o):
            return selectionRect.intersects(o.rect)
        case .image(let o):
            return selectionRect.intersects(o.rect)
        case .blur(let o):
            return selectionRect.intersects(o.rect)
        }
    }

    func boundingBoxOfSelectedObjects() -> CGRect? {
        guard !selectedObjectIDs.isEmpty else { return nil }

        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity

        for obj in objects {
            guard selectedObjectIDs.contains(obj.id) else { continue }

            switch obj {
            case .line(let o):
                minX = min(minX, min(o.start.x, o.end.x))
                maxX = max(maxX, max(o.start.x, o.end.x))
                minY = min(minY, min(o.start.y, o.end.y))
                maxY = max(maxY, max(o.start.y, o.end.y))
            case .rect(let o):
                minX = min(minX, o.rect.minX)
                maxX = max(maxX, o.rect.maxX)
                minY = min(minY, o.rect.minY)
                maxY = max(maxY, o.rect.maxY)
            case .oval(let o):
                minX = min(minX, o.rect.minX)
                maxX = max(maxX, o.rect.maxX)
                minY = min(minY, o.rect.minY)
                maxY = max(maxY, o.rect.maxY)
            case .text(let o):
                minX = min(minX, o.rect.minX)
                maxX = max(maxX, o.rect.maxX)
                minY = min(minY, o.rect.minY)
                maxY = max(maxY, o.rect.maxY)
            case .badge(let o):
                minX = min(minX, o.rect.minX)
                maxX = max(maxX, o.rect.maxX)
                minY = min(minY, o.rect.minY)
                maxY = max(maxY, o.rect.maxY)
            case .highlight(let o):
                minX = min(minX, o.rect.minX)
                maxX = max(maxX, o.rect.maxX)
                minY = min(minY, o.rect.minY)
                maxY = max(maxY, o.rect.maxY)
            case .image(let o):
                minX = min(minX, o.rect.minX)
                maxX = max(maxX, o.rect.maxX)
                minY = min(minY, o.rect.minY)
                maxY = max(maxY, o.rect.maxY)
            case .blur(let o):
                minX = min(minX, o.rect.minX)
                maxX = max(maxX, o.rect.maxX)
                minY = min(minY, o.rect.minY)
                maxY = max(maxY, o.rect.maxY)
            }
        }

        guard minX != .infinity else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func fittedImageSize(original: CGSize, in container: CGSize) -> CGSize {
        let scale = min(container.width / max(1, original.width), container.height / max(1, original.height))
        return CGSize(width: original.width * scale, height: original.height * scale)
    }
    
    func uiToImagePoint(_ p: CGPoint, fitted: CGSize, image: CGSize) -> CGPoint {
        let p = clampPoint(p, in: fitted)
        let scaleX = image.width / max(1, fitted.width)
        let scaleY = image.height / max(1, fitted.height)
        // UI: (0,0) top-left (Y down) -> Image: (0,0) bottom-left (Y up)
        return CGPoint(x: p.x * scaleX, y: (fitted.height - p.y) * scaleY)
    }
    
    func uiRectToImageRect(_ r: CGRect, fitted: CGSize, image: CGSize) -> CGRect {
        let r = clampRect(r, in: fitted)
        let scaleX = image.width / max(1, fitted.width)
        let scaleY = image.height / max(1, fitted.height)
        let x = r.origin.x * scaleX
        let width = r.width * scaleX
        let height = r.height * scaleY
        // Convert Y coordinate: UI top-left origin to image bottom-left origin
        let y = (fitted.height - (r.origin.y + r.height)) * scaleY
        return CGRect(x: x, y: y, width: width, height: height)
    }
    
    // Shift Snipping for straight lines at 0°/45°/90°
    func SnippedPoint(start: CGPoint, raw: CGPoint) -> CGPoint {
        let dx = raw.x - start.x
        let dy = raw.y - start.y
        let adx = abs(dx)
        let ady = abs(dy)
        if adx == 0 && ady == 0 { return raw }
        // Thresholds for 22.5° and 67.5° to decide Snipping band
        let tan22: CGFloat = 0.41421356  // tan(22.5°)
        let tan67: CGFloat = 2.41421356  // tan(67.5°)
        
        if ady <= adx * tan22 { // Horizontal
            return CGPoint(x: start.x + dx, y: start.y)
        } else if ady >= adx * tan67 { // Vertical
            return CGPoint(x: start.x, y: start.y + dy)
        } else { // Diagonal 45°
            let m = max(adx, ady)
            let sx: CGFloat = dx >= 0 ? 1 : -1
            let sy: CGFloat = dy >= 0 ? 1 : -1
            return CGPoint(x: start.x + sx * m, y: start.y + sy * m)
        }
    }
    
    func pasteFromClipboard() {
        // If a TextEditor is focused, let it handle paste itself.
        if isTextEditorFocused { return }
        
        let pb = NSPasteboard.general
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let img = imgs.first {
            // Choose author space (object coord system)
            let author = objectSpaceSize ?? lastFittedSize ?? currentImage?.size ?? CGSize(width: 1200, height: 800)
            
            let natural = img.size
            let aspect = (natural.height == 0) ? 1 : (natural.width / natural.height)
            
            // Sensible default size
            var w = min(480, author.width * 0.6)
            var h = w / aspect
            if h > author.height * 0.6 { h = author.height * 0.6; w = h * aspect }
            
            // Center in author space
            let rect = CGRect(
                x: max(0, (author.width - w)/2),
                y: max(0, (author.height - h)/2),
                width: w, height: h
            )
            
            let obj = PastedImageObject(rect: rect, image: img)
            pushUndoSnipshot()
            objects.append(.image(obj))
            if objectSpaceSize == nil { objectSpaceSize = author }
            selectedObjectID = obj.id
            activeHandle = .none
            // no focus change for text
        }
    }
    
    // MARK: - Snips Persistence
    
    func SnipsDirectory() -> URL? {
        // If the user has chosen a custom destination, resolve from bookmark
        if !saveDirectoryPath.isEmpty {
            if let bookmarkData = UserDefaults.standard.data(forKey: "saveDirectoryBookmark") {
                do {
                    var isStale = false
                    let url = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    
                    guard url.startAccessingSecurityScopedResource() else {
                        print("Failed to access security-scoped resource")
                        return defaultSnipsDirectory()
                    }
                    
                    // Store a reference to stop accessing later if needed
                    // You might want to manage this lifecycle better
                    return url
                    
                } catch {
                    print("Failed to resolve bookmark: \(error)")
                    // Fall back to default directory
                    return defaultSnipsDirectory()
                }
            }
        }
        
        return defaultSnipsDirectory()
    }

    func defaultSnipsDirectory() -> URL? {
        let fm = FileManager.default
        if let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
            let dir = pictures.appendingPathComponent("Screen Snip", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        return nil
    }
    
    var currentImage: NSImage? {
        guard let url = selectedSnipURL else { return nil }
        return NSImage(contentsOf: url)  // Load on-demand
    }
    
    /// Loads existing Snips on disk (all supported formats), newest first.
    func loadExistingSnips() {
        guard let dir = SnipsDirectory() else { return }
        let fm = FileManager.default
        do {
            let supportedExtensions = Set(["png", "jpg", "jpeg", "heic"])
            let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
                .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            let dated: [(URL, Date)] = urls.compactMap {
                let vals = try? $0.resourceValues(forKeys: [.creationDateKey])
                return ($0, vals?.creationDate ?? .distantPast)
            }
            let sorted = dated.sorted { $0.1 > $1.1 }.map { $0.0 }
            SnipURLs = Array(sorted.prefix(10))
            
            // Clean up missing URLs from our tracking set
            missingSnipURLs = missingSnipURLs.filter { !sorted.contains($0) }
            
            // If currently selected Snip no longer exists, clear selection
            if let sel = selectedSnipURL {
                if !fm.fileExists(atPath: sel.path) {
                    selectedSnipURL = nil
                }
            }
        } catch {
            SnipURLs = []
        }
    }
    
    /// Opens the Snips directory in Finder as a simple "gallery" view.
    func openSnipsInFinder() {
        guard let dir = SnipsDirectory() else { return }
        NSWorkspace.shared.open(dir)
    }
    
    func openSnipsInGallery() {
        // First, refresh the main view's data
        loadExistingSnips()
        
        // Create a function that builds on the refreshed main data
        func loadAllGalleryURLs() -> [URL] {
            guard let dir = SnipsDirectory() else { return [] }
            let fm = FileManager.default
            do {
                let supportedExtensions = Set(["png", "jpg", "jpeg", "heic"])
                let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
                    .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
                let dated: [(URL, Date)] = urls.compactMap {
                    let vals = try? $0.resourceValues(forKeys: [.creationDateKey])
                    return ($0, vals?.creationDate ?? .distantPast)
                }
                // Return ALL files (not limited to 10 like SnipURLs)
                return dated.sorted { $0.1 > $1.1 }.map { $0.0 }
            } catch {
                return []
            }
        }
        
        // Use the already-refreshed SnipURLs as the immediate data source, then load all files
        let initialUrls = loadAllGalleryURLs()
        guard !initialUrls.isEmpty else { return }
        
        GalleryWindow.shared.present(
            urls: initialUrls,
            onSelect: { url in
                // Your existing onSelect code...
                let fm = FileManager.default
                if !fm.fileExists(atPath: url.path) {
                    missingSnipURLs.insert(url)
                    if let index = SnipURLs.firstIndex(of: url) {
                        SnipURLs.remove(at: index)
                    }
                    return
                }
                
                selectedSnipURL = url
                selectedImageSize = probeImageSize(url)
                objects.removeAll()
                objectSpaceSize = nil
                selectedObjectID = nil
                activeHandle = .none
                cropRect = nil
                cropDraftRect = nil
                cropHandle = .none
                focusedTextID = nil
                undoStack.removeAll()
                redoStack.removeAll()
                zoomLevel = 1.0
                imageReloadTrigger = UUID()
                GalleryWindow.shared.close()
            },
            onReload: loadAllGalleryURLs  // Use the same function for reload
        )
    }
    
    /// Inserts a newly saved URL at the start of the list (leftmost), de-duplicating if necessary.
    func insertSnipURL(_ url: URL) {
        if let idx = SnipURLs.firstIndex(of: url) {
            SnipURLs.remove(at: idx)
        }
        SnipURLs.insert(url, at: 0)
    }
    
    /// Delete a Snip from disk and update gallery/selection.
    func deleteSnip(_ url: URL) {
        let fm = FileManager.default
        // Prefer moving to Trash; fall back to remove.
        do {
            var trashedURL: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &trashedURL)
        } catch {
            try? fm.removeItem(at: url)
        }
        // Update gallery list
        if let idx = SnipURLs.firstIndex(of: url) {
            SnipURLs.remove(at: idx)
        }
        // Update current selection / preview
        if selectedSnipURL == url {
            selectedSnipURL = SnipURLs.first
            if let sel = selectedSnipURL {
                selectedImageSize = probeImageSize(sel)
                lastFittedSize = nil
            } else {
                selectedImageSize = nil
                lastFittedSize = nil
            }
        }
    }
    
    func cropImage(_ image: NSImage, toBottomLeftRect rBL: CGRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)
        // Convert to CoreGraphics top-left origin
        var rectTL = CGRect(x: rBL.origin.x,
                            y: imgH - (rBL.origin.y + rBL.height),
                            width: rBL.width,
                            height: rBL.height)
        // Normalize negative or tiny sizes
        if rectTL.width < 0 { rectTL.origin.x += rectTL.width; rectTL.size.width = -rectTL.width }
        if rectTL.height < 0 { rectTL.origin.y += rectTL.height; rectTL.size.height = -rectTL.height }
        // Clamp to image bounds
        rectTL.origin.x = max(0, min(rectTL.origin.x, imgW))
        rectTL.origin.y = max(0, min(rectTL.origin.y, imgH))
        rectTL.size.width  = max(1, min(rectTL.size.width,  imgW - rectTL.origin.x))
        rectTL.size.height = max(1, min(rectTL.size.height, imgH - rectTL.origin.y))
        // Integral pixel edges
        rectTL = rectTL.integral
        guard rectTL.width >= 1, rectTL.height >= 1 else { return nil }
        guard let sub = cg.cropping(to: rectTL) else { return nil }
        return NSImage(cgImage: sub, size: NSSize(width: rectTL.width, height: rectTL.height))
    }
    
}
