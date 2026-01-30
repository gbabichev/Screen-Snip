import SwiftUI
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import UniformTypeIdentifiers
import ImageIO
import Combine

// MARK: - Centralized Image Saving
struct ImageSaver {

    private nonisolated static func fileExtension(for format: String) -> String {
        switch format.lowercased() {
        case "jpeg": return "jpg"
        case "heic": return "heic"
        default: return "png"
        }
    }

    nonisolated static func urlByEnsuringExtension(for url: URL, format: String) -> URL {
        let desiredExtension = fileExtension(for: format)
        let currentExtension = url.pathExtension.lowercased()
        if currentExtension == desiredExtension {
            return url
        }
        let baseURL = currentExtension.isEmpty ? url : url.deletingPathExtension()
        return baseURL.appendingPathExtension(desiredExtension)
    }

    /// Write an image, adjusting the filename extension when needed. Returns the final URL on success.
    nonisolated static func writeImageReplacing(_ image: NSImage,
                                                at originalURL: URL,
                                                format: String,
                                                quality: Double,
                                                preserveAttributes: Bool = false) -> URL? {
        let targetURL = urlByEnsuringExtension(for: originalURL, format: format)
        let fm = FileManager.default

        var originalCreationDate: Date?
        if preserveAttributes,
           let attrs = try? fm.attributesOfItem(atPath: originalURL.path),
           let creation = attrs[.creationDate] as? Date {
            originalCreationDate = creation
        }

        let shouldPreserveAttributesInWrite = preserveAttributes && targetURL == originalURL

        let success = writeImage(
            image,
            to: targetURL,
            format: format,
            quality: quality,
            preserveAttributes: shouldPreserveAttributesInWrite
        )

        guard success else { return nil }

        if preserveAttributes, targetURL != originalURL, let creationDate = originalCreationDate {
            do {
                try fm.setAttributes([.creationDate: creationDate], ofItemAtPath: targetURL.path)
            } catch {
                print("Could not transfer original creation date: \(error)")
            }
        }

        if targetURL != originalURL {
            do {
                if fm.fileExists(atPath: originalURL.path) {
                    try fm.removeItem(at: originalURL)
                }
            } catch {
                print("Could not remove original file after format change: \(error)")
            }
        }

        return targetURL
    }
    
    private static func generateFilename(fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return "Snip_\(formatter.string(from: Date())).\(fileExtension)"
    }
    
    static func saveImage(_ image: NSImage, to directory: URL? = nil) -> URL? {
        // Get user preferences from UserDefaults
        let saveDirectoryPath = UserDefaults.standard.string(forKey: "saveDirectoryPath") ?? ""
        let preferredSaveFormatRaw = UserDefaults.standard.string(forKey: "preferredSaveFormat") ?? "png"
        let saveQuality = UserDefaults.standard.double(forKey: "saveQuality")
        let quality = saveQuality > 0 ? saveQuality : 0.9 // Default to 0.9 if not set
        
        // Determine save format and extension
        let (format, fileExt): (String, String) = {
            let ext = fileExtension(for: preferredSaveFormatRaw)
            return (preferredSaveFormatRaw, ext)
        }()
        
        // Determine save directory
        let saveDir: URL
        if let directory = directory {
            saveDir = directory
        } else if !saveDirectoryPath.isEmpty {
            saveDir = URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        } else {
            guard let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else { return nil }
            saveDir = pictures.appendingPathComponent("Screen Snip", isDirectory: true)
            if !FileManager.default.fileExists(atPath: saveDir.path) {
                try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            }
        }
        
        let filename = generateFilename(fileExtension: fileExt)
        let url = saveDir.appendingPathComponent(filename)
        
        // Save the image
        return writeImage(image, to: url, format: format, quality: quality) ? url : nil
    }
    
    static func generateFilename(for format: String) -> String {
        return generateFilename(fileExtension: fileExtension(for: format))
    }

    /// Replaces the file extension of a given filename with the extension for the specified format
    static func replaceExtension(of filename: String, with format: String) -> String {
        let url = URL(fileURLWithPath: filename)
        let nameWithoutExtension = url.deletingPathExtension().lastPathComponent
        return "\(nameWithoutExtension).\(fileExtension(for: format))"
    }
    
    nonisolated static func writeImage(_ image: NSImage, to url: URL, format: String, quality: Double, preserveAttributes: Bool = false) -> Bool {
        var originalCreationDate: Date? = nil
        
        // Capture original creation date if preserving and file exists
        if preserveAttributes && FileManager.default.fileExists(atPath: url.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                originalCreationDate = attributes[.creationDate] as? Date
            } catch {
                // If we can't read attributes, continue anyway
                print("Could not read original file attributes: \(error)")
            }
        }
        
        // Check if user wants to downsample to non-retina
        let downsampleToNonRetinaForSave = UserDefaults.standard.bool(forKey: "downsampleToNonRetinaForSave")
        
        // Get the image's current scale
        let originalScale = image.recommendedLayerContentsScale(0.0)
        _ = downsampleToNonRetinaForSave ? 1.0 : originalScale
        
        // For PNG, use the original method since it works
        if format == "png" {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return false }
            
            let data = rep.representation(using: .png, properties: [:])
            guard let pngData = data else { return false }
            
            do {
                try pngData.write(to: url, options: .atomic)
                
                // Restore original creation date if we captured it
                if preserveAttributes, let creationDate = originalCreationDate {
                    do {
                        try FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: url.path)
                    } catch {
                        print("Could not restore original creation date: \(error)")
                    }
                }
                
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

        #if DEBUG
        print("[ImageSaver] NSImage.size (pt)=\(Int(pointsWidth))x\(Int(pointsHeight)) cg=\(dbg_cgW)x\(dbg_cgH) bestRep=\(dbg_repW)x\(dbg_repH) class=\(dbg_bestRepClass) scaleFromRep=\(String(format: "%.2f", Double(scaleFromRep))) downsample=\(downsampleToNonRetinaForSave)")
        #endif
        
        // Effective output scale: 1x if explicitly downsampling, otherwise preserve backing scale (e.g., 2x)
        let effectiveScale = CGFloat(downsampleToNonRetinaForSave ? 1.0 : max(1.0, scaleFromRep))

        // Target pixels: keep original backing pixels unless downsampling to 1x
        let targetPixelsWide = downsampleToNonRetinaForSave ? Int(round(pointsWidth * 1.0)) : backingWidth
        let targetPixelsHigh = downsampleToNonRetinaForSave ? Int(round(pointsHeight * 1.0)) : backingHeight

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
        
        #if DEBUG
        print("[ImageSaver] targetPixels=\(targetPixelsWide)x\(targetPixelsHigh) effectiveScale=\(String(format: "%.2f", Double(effectiveScale))) dpi=\(dpi) format=\(format)")
        #endif
        
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
        let success = CGImageDestinationFinalize(destination)
        
        // Restore original creation date if we captured it and write was successful
        if success, preserveAttributes, let creationDate = originalCreationDate {
            do {
                try FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: url.path)
            } catch {
                print("Could not restore original creation date: \(error)")
                // Don't fail the operation just because we couldn't restore the date
            }
        }
        
        return success
    }
    
    
    
    nonisolated static func imageData(from image: NSImage, format: String, quality: Double) -> Data? {
        // For PNG, use NSBitmapImageRep since it's reliable and simple
        if format.lowercased() == "png" {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
            return pngData
        }

        // For JPEG and HEIC, use CGImageDestination which properly supports both formats
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return imageData(from: cgImage, format: format, quality: quality)
    }

    nonisolated static func imageData(from cgImage: CGImage, format: String, quality: Double) -> Data? {
        let utType: CFString = {
            switch format.lowercased() {
            case "jpeg", "jpg": return UTType.jpeg.identifier as CFString
            case "heic": return UTType.heic.identifier as CFString
            default: return UTType.png.identifier as CFString
            }
        }()

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, utType, 1, nil) else { return nil }

        let properties: [CFString: Any]
        if format.lowercased() == "png" {
            properties = [:]
        } else {
            properties = [kCGImageDestinationLossyCompressionQuality: quality]
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }

        return mutableData as Data
    }

    nonisolated static func scaledCGImage(_ cgImage: CGImage, factor: CGFloat) -> CGImage? {
        let f = max(0.01, min(factor, 1.0))
        guard f < 0.999 else { return cgImage }

        let targetWidth = max(1, Int(round(CGFloat(cgImage.width) * f)))
        let targetHeight = max(1, Int(round(CGFloat(cgImage.height) * f)))

        guard let ctx = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return ctx.makeImage()
    }
    
}

struct ImageDocument: FileDocument {
    nonisolated(unsafe) static var readableContentTypes: [UTType] = [.png, .jpeg, .heic]
    nonisolated(unsafe) static var writableContentTypes: [UTType] = [.png, .jpeg, .heic]
    
    let image: NSImage
    let scaleFactor: CGFloat
    let quality: Double
    
    init(image: NSImage, scaleFactor: CGFloat = 1.0, quality: Double = 0.9) {
        self.image = image
        self.scaleFactor = scaleFactor
        self.quality = quality
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let image = NSImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.image = image
        self.scaleFactor = 1.0
        self.quality = 0.9
    }
    
    private func scaledImage(_ image: NSImage, factor: CGFloat) -> NSImage {
        let f = max(0.01, min(factor, 1.0))
        guard f < 0.999 else { return image }

        // Prefer CG-based scaling to preserve pixel density and avoid 72-DPI lockFocus fallback.
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let targetWidth = max(1, Int(round(CGFloat(cg.width) * f)))
            let targetHeight = max(1, Int(round(CGFloat(cg.height) * f)))

            guard let ctx = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return image }

            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

            if let scaledCG = ctx.makeImage() {
                let nsImage = NSImage(cgImage: scaledCG, size: NSSize(width: CGFloat(targetWidth), height: CGFloat(targetHeight)))
                return nsImage
            }
        }

        // Fallback: lockFocus-based scaling.
        let newSize = NSSize(width: image.size.width * f, height: image.size.height * f)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Honor the user's chosen type in the save panel; fall back to preference if unavailable.
        let format: String = {
            let type = configuration.contentType
            switch type {
            case .png:  return "png"
            case .jpeg: return "jpeg"
            case .heic: return "heic"
            default:
                return UserDefaults.standard.string(forKey: "preferredSaveFormat") ?? "png"
            }
        }()
        // Fetch the latest scale/quality selections from defaults so changes made in the sheet are respected at save time.
        let liveScale: CGFloat = {
            let v = UserDefaults.standard.double(forKey: "exportScaleFactor")
            return v > 0 ? CGFloat(v) : scaleFactor
        }()
        let liveQuality: Double = {
            let v = UserDefaults.standard.double(forKey: "exportQuality")
            if v > 0 { return v }
            let q = UserDefaults.standard.double(forKey: "saveQuality")
            return q > 0 ? q : quality
        }()
        let source = (liveScale < 0.999) ? scaledImage(image, factor: max(0.01, liveScale)) : image
        
        guard let data = ImageSaver.imageData(from: source, format: format, quality: liveQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        
        return FileWrapper(regularFileWithContents: data)
    }
}
