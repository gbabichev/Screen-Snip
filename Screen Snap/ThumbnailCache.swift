//
//  ThumbnailCache.swift
//  Screen Snap
//
//  Created by George Babichev on 9/12/25.
//


import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ImageIO

// MARK: - Tiny in-memory cache for thumbnails
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    private init() { cache.countLimit = 500 } // tune if needed

    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func insert(_ image: NSImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

// MARK: - Async thumbnail creation (Quick Look first, CoreGraphics fallback)
enum ThumbGen {
    static func makeThumbnail(url: URL, targetSize: CGSize, scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2) async -> NSImage? {
        // 1) Quick Look (fast and format-aware, doesn’t decode originals to full size)
        if let ql = await qlThumbnail(url: url, targetSize: targetSize, scale: scale) {
            return ql
        }
        // 2) CoreGraphics thumbnail (no full decode)
        return cgThumbnail(url: url, maxPixel: Int(max(targetSize.width, targetSize.height) * scale))
    }

    private static func qlThumbnail(url: URL, targetSize: CGSize, scale: CGFloat) async -> NSImage? {
        let types: QLThumbnailGenerator.Request.RepresentationTypes = [.thumbnail, .lowQualityThumbnail]
        let req = QLThumbnailGenerator.Request(fileAt: url, size: targetSize, scale: scale, representationTypes: types)
        return await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                guard let rep else { cont.resume(returning: nil); return }
                cont.resume(returning: rep.asNSImage)
            }
        }
    }

    private static func cgThumbnail(url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero) // size auto-derived by AppKit
    }
}

private extension QLThumbnailRepresentation {
    var asNSImage: NSImage {
        // On macOS, QLThumbnailRepresentation exposes a non-optional CGImage.
        // Build an NSImage directly without touching any full-size original.
        NSImage(cgImage: self.cgImage, size: .zero)
    }
}
