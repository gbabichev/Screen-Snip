//
//  ImageSaver.swift
//  Screen Snap
//
//  Created by George Babichev on 9/12/25.
//



import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Centralized Image Saving
struct ImageSaver {
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
        
        // Generate filename
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let filename = "snap_\(formatter.string(from: Date())).\(fileExtension)"
        let url = saveDir.appendingPathComponent(filename)
        
        // Save the image
        return writeImage(image, to: url, format: format, quality: quality) ? url : nil
    }
    
    static func writeImage(_ image: NSImage, to url: URL, format: String, quality: Double) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return false }
        
        let data: Data?
        switch format {
        case "png":
            data = rep.representation(using: .png, properties: [:])
        case "jpeg":
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        case "heic":
            guard let cgimg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                data = nil
                break
            }
            let mutable = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                mutable as CFMutableData,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else {
                data = nil
                break
            }
            
            let props: CFDictionary = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            CGImageDestinationAddImage(dest, cgimg, props)
            
            data = CGImageDestinationFinalize(dest) ? (mutable as Data) : nil
        default:
            data = rep.representation(using: .png, properties: [:])
        }
        
        guard let data else { return false }
        
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
