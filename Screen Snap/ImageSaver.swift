import Foundation
import AppKit
import UniformTypeIdentifiers
import ImageIO

// MARK: - Centralized Image Saving
struct ImageSaver {
    
    private static func generateFilename(fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return "Gsnap_\(formatter.string(from: Date())).\(fileExtension)"
    }
    
    static func saveImage(_ image: NSImage, to directory: URL? = nil) -> URL? {
        // Get user preferences from UserDefaults
        let saveDirectoryPath = UserDefaults.standard.string(forKey: "saveDirectoryPath") ?? ""
        let preferredSaveFormatRaw = UserDefaults.standard.string(forKey: "preferredSaveFormat") ?? "png"
        let saveQuality = UserDefaults.standard.double(forKey: "saveQuality")
        let quality = saveQuality > 0 ? saveQuality : 0.9 // Default to 0.9 if not set
        
        // Determine save format and extension
        let (format, fileExtension): (String, String) = {
            switch preferredSaveFormatRaw {
            case "jpeg": return ("jpeg", "jpg")
            case "heic": return ("heic", "heic")
            default: return ("png", "png")
            }
        }()
        
        // Determine save directory
        let saveDir: URL
        if let directory = directory {
            saveDir = directory
        } else if !saveDirectoryPath.isEmpty {
            saveDir = URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        } else {
            guard let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else { return nil }
            saveDir = pictures.appendingPathComponent("Screen Snap", isDirectory: true)
            if !FileManager.default.fileExists(atPath: saveDir.path) {
                try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            }
        }
        
        let filename = generateFilename(fileExtension: fileExtension)
        let url = saveDir.appendingPathComponent(filename)
        
        // Save the image
        return writeImage(image, to: url, format: format, quality: quality) ? url : nil
    }
    
    static func generateFilename(for format: String) -> String {
        let fileExtension: String = {
            switch format {
            case "jpeg": return "jpg"
            case "heic": return "heic"
            default: return "png"
            }
        }()
        return generateFilename(fileExtension: fileExtension)
    }
    
    static func writeImage(_ image: NSImage, to url: URL, format: String, quality: Double) -> Bool {
        // Check if user wants to downsample to non-retina
        let downsampleToNonRetina = UserDefaults.standard.bool(forKey: "downsampleToNonRetina")
        
        // Get the image's current scale
        let originalScale = image.recommendedLayerContentsScale(0.0)
        let targetScale = downsampleToNonRetina ? 1.0 : originalScale
        
        // For PNG, use the original method since it works
        if format == "png" {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return false }
            
            let data = rep.representation(using: .png, properties: [:])
            guard let pngData = data else { return false }
            
            do {
                try pngData.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
        
        // For JPEG and HEIC, explicitly rasterize at the desired pixel scale, preserving backing pixel dimensions when not downsampling.
        // DEBUG: collect representation info
        var dbg_cgW: Int = -1
        var dbg_cgH: Int = -1
        var dbg_repW: Int = -1
        var dbg_repH: Int = -1
        var dbg_bestRepClass: String = "none"
        
        var backingWidth = Int(round(image.size.width))
        var backingHeight = Int(round(image.size.height))
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            backingWidth = cg.width
            backingHeight = cg.height
            dbg_cgW = cg.width
            dbg_cgH = cg.height
        } else if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }) {
            backingWidth = rep.pixelsWide
            backingHeight = rep.pixelsHigh
            dbg_repW = rep.pixelsWide
            dbg_repH = rep.pixelsHigh
            dbg_bestRepClass = String(describing: type(of: rep))
        }

        let pointsWidth = max(1.0, image.size.width)
        let pointsHeight = max(1.0, image.size.height)
        let scaleFromRepW = CGFloat(backingWidth) / CGFloat(pointsWidth)
        let scaleFromRepH = CGFloat(backingHeight) / CGFloat(pointsHeight)
        let scaleFromRep = max(scaleFromRepW, scaleFromRepH)

        print("[ImageSaver] NSImage.size (pt)=\(Int(pointsWidth))x\(Int(pointsHeight)) cg=\(dbg_cgW)x\(dbg_cgH) bestRep=\(dbg_repW)x\(dbg_repH) class=\(dbg_bestRepClass) scaleFromRep=\(String(format: "%.2f", Double(scaleFromRep))) downsample=\(downsampleToNonRetina)")

        // Effective output scale: 1x if explicitly downsampling, otherwise preserve backing scale (e.g., 2x)
        let effectiveScale = CGFloat(downsampleToNonRetina ? 1.0 : max(1.0, scaleFromRep))

        // Target pixels: keep original backing pixels unless downsampling to 1x
        let targetPixelsWide = downsampleToNonRetina ? Int(round(pointsWidth * 1.0)) : backingWidth
        let targetPixelsHigh = downsampleToNonRetina ? Int(round(pointsHeight * 1.0)) : backingHeight

        guard let finalRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, targetPixelsWide),
            pixelsHigh: max(1, targetPixelsHigh),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }

        // Set logical size equal to pixel size so 1 unit = 1 pixel during draw
        finalRep.size = NSSize(width: CGFloat(targetPixelsWide), height: CGFloat(targetPixelsHigh))

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: finalRep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high

            let drawRect = NSRect(x: 0, y: 0, width: finalRep.size.width, height: finalRep.size.height)

            // Prefer drawing the CGImage/backing rep directly to avoid NSImage scale ambiguity
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.cgContext.interpolationQuality = .high
                ctx.cgContext.draw(cg, in: drawRect)
            } else if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }), let cg = rep.cgImage {
                ctx.cgContext.interpolationQuality = .high
                ctx.cgContext.draw(cg, in: drawRect)
            } else {
                // Fallback
                image.draw(in: drawRect)
            }
            ctx.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = finalRep.cgImage else { return false }

        // Match DPI metadata to the pixel scale so apps that honor DPI retain the visual size
        let dpi = 72.0 * Double(effectiveScale)
        
        print("[ImageSaver] targetPixels=\(targetPixelsWide)x\(targetPixelsHigh) effectiveScale=\(String(format: "%.2f", Double(effectiveScale))) dpi=\(dpi) format=\(format)")
        
        // Determine UTType
        let utType: CFString = {
            switch format {
            case "jpeg": return UTType.jpeg.identifier as CFString
            case "heic": return UTType.heic.identifier as CFString
            default: return UTType.png.identifier as CFString
            }
        }()
        
        // Create destination
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            utType,
            1,
            nil
        ) else {
            return false
        }
        
        // Create properties dictionary based on format
        let properties: [CFString: Any] = {
            switch format {
            case "jpeg":
                let dpiInt = Int(round(dpi))
                return [
                    kCGImageDestinationLossyCompressionQuality: quality,
                    kCGImagePropertyJFIFDictionary: [
                        kCGImagePropertyJFIFVersion: [1, 1],
                        kCGImagePropertyJFIFIsProgressive: false,
                        kCGImagePropertyJFIFXDensity: dpiInt,
                        kCGImagePropertyJFIFYDensity: dpiInt,
                        kCGImagePropertyJFIFDensityUnit: 1 // 1 = dots per inch
                    ],
                    kCGImagePropertyTIFFDictionary: [
                        kCGImagePropertyTIFFXResolution: dpi,
                        kCGImagePropertyTIFFYResolution: dpi,
                        kCGImagePropertyTIFFResolutionUnit: 2 // 2 = inch
                    ]
                ]
            case "heic":
                return [
                    kCGImageDestinationLossyCompressionQuality: quality,
                    kCGImagePropertyDPIWidth: dpi,
                    kCGImagePropertyDPIHeight: dpi
                ]
            default: // PNG
                return [
                    kCGImagePropertyDPIWidth: dpi,
                    kCGImagePropertyDPIHeight: dpi
                ]
            }
        }()
        
        // Add image with properties and finalize
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
