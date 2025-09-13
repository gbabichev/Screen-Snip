import SwiftUI
import AppKit
import VideoToolbox
import UniformTypeIdentifiers
import ImageIO

// MARK: - Gallery Window + View

/// Simple NSWindow wrapper to present a SwiftUI gallery of thumbnails.
final class GalleryWindow {
    static let shared = GalleryWindow()
    private var window: NSWindow?
    
    func present(urls: [URL], onSelect: @escaping (URL) -> Void, onReload: @escaping () -> [URL]) {
        // If already visible, just bring to front and update content
        if let win = window {
            // Refresh content in the existing window
            if let hosting = win.contentViewController as? NSHostingController<GalleryView> {
                hosting.rootView = GalleryView(urls: urls, onSelect: onSelect, onReload: onReload)
            } else {
                win.contentViewController = NSHostingController(rootView: GalleryView(urls: urls, onSelect: onSelect, onReload: onReload))
            }
            // Enforce a sane size if it somehow got too small
            win.minSize = NSSize(width: 480, height: 360)
            var f = win.frame
            if f.width < 600 || f.height < 400 {
                f.size.width = max(f.width, 820)
                f.size.height = max(f.height, 620)
                win.setFrame(f, display: false)
            }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let content = GalleryView(urls: urls, onSelect: onSelect, onReload: onReload)
        let hosting = NSHostingController(rootView: content)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        //win.titleVisibility = .hidden
        win.title = "Snap Gallery"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.tabbingMode = .disallowed
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 900, height: 600)
        win.contentViewController = hosting
        
        // Create controller and set up autosave through the controller
        let controller = NSWindowController(window: win)
        let autosaveName = "SnapGalleryWindowV2"
        controller.windowFrameAutosaveName = autosaveName
        
        self.window = win
        
        // Set up close handler
        let closeHandler = WindowCloseHandler() { [weak self] in
            self?.window = nil
        }
        win.delegate = closeHandler
        
        // Show the window - this will trigger automatic frame restoration
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Post-show validation and adjustment
        DispatchQueue.main.async {
            let minW: CGFloat = 900
            let minH: CGFloat = 600
            let vf = (win.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = win.frame
            let tooSmall = frame.width < minW || frame.height < minH
            let padding: CGFloat = 20
            let safeVisible = vf.insetBy(dx: padding, dy: padding)
            let center = NSPoint(x: frame.midX, y: frame.midY)
            let offscreen = !safeVisible.contains(center)
            
            if tooSmall || offscreen {
                let targetW = max(minW, min(vf.width * 0.8, 1800))
                let targetH = max(minH, min(vf.height * 0.85, 1200))
                let targetX = vf.midX - targetW / 2
                let targetY = vf.midY - targetH / 2
                win.setFrame(NSRect(x: targetX, y: targetY, width: targetW, height: targetH), display: true)
            }
        }
    }
    
    private final class WindowCloseHandler: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        
        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }
        
        func windowWillClose(_ notification: Notification) {
            onClose()
        }
    }
    
    func close() {
        window?.close()
        window = nil
    }
}

/// SwiftUI gallery view: scrollable grid of thumbnails that calls `onSelect(url)` when tapped.
struct GalleryView: View {
    let onSelect: (URL) -> Void
    let onReload: () -> [URL]
    @State private var urlsLocal: [URL]
    @State private var selectedUrl: URL?
    @State private var refreshTrigger = UUID()
    
    @AppStorage("saveDirectoryPath") private var saveDirectoryPath: String = ""
    
    private func snapsDirectoryFromSettings() -> URL? {
        if !saveDirectoryPath.isEmpty {
            return URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        }
        let fm = FileManager.default
        if let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first {
            let dir = pictures.appendingPathComponent("Screen Snap", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
        return nil
    }
    
    private func openSnapsInFinder() {
        guard let dir = snapsDirectoryFromSettings() else { return }
        NSWorkspace.shared.open(dir)
    }
    
    private func deleteFile(at url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            urlsLocal.removeAll { $0 == url }
            if selectedUrl == url {
                selectedUrl = nil
            }
        } catch {
            print("Failed to delete file: \(error)")
        }
    }
    
    init(urls: [URL], onSelect: @escaping (URL) -> Void, onReload: @escaping () -> [URL]) {
        self.onSelect = onSelect
        self.onReload = onReload
        _urlsLocal = State(initialValue: urls)
    }
    
    // Basic grid: adapts to window size
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 192), spacing: 8)] // Slightly larger to account for ThumbnailView's padding
    }
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(urlsLocal, id: \.self) { url in
                    ThumbnailView(
                        url: url,
                        selected: selectedUrl == url,
                        onDelete: { deleteFile(at: url) },
                        width: 180,
                        height: 120,
                        refreshTrigger: refreshTrigger
                    )
                    .onTapGesture {
                        selectedUrl = url
                        onSelect(url)
                    }
                }
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    urlsLocal = onReload()
                    refreshTrigger = UUID() // Force thumbnail refresh
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Button {
                    openSnapsInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity,
               minHeight: 360, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
