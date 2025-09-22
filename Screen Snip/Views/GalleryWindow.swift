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
            
            let freshUrls = onReload()
            
            // Always create a new hosting controller with fresh data to ensure SwiftUI updates
            let content = GalleryView(urls: freshUrls, onSelect: onSelect, onReload: onReload, onVisibleDateChange: { [weak win] date in
                win?.title = date.map { "Snip Gallery — \($0)" } ?? "Snip Gallery"
            })
            win.contentViewController = NSHostingController(rootView: content)
            
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
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        let content = GalleryView(urls: onReload(), onSelect: onSelect, onReload: onReload, onVisibleDateChange: { [weak win] date in
            win?.title = date.map { "Snip Gallery — \($0)" } ?? "Snip Gallery"
        })
        let hosting = NSHostingController(rootView: content)
        
        //win.titleVisibility = .hidden
        win.title = "Snip Gallery"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.tabbingMode = .disallowed
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 900, height: 600)
        win.contentViewController = hosting
        
        // Create controller and set up autosave through the controller
        let controller = NSWindowController(window: win)
        let autosaveName = "SnipGalleryWindowV2"
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
    let onVisibleDateChange: (String?) -> Void
    @State private var urlsLocal: [URL]
    @State private var selectedUrl: URL?
    @State private var refreshTrigger = UUID()
    @State private var currentVisibleDate: String? = nil
    
    @AppStorage("saveDirectoryPath") private var saveDirectoryPath: String = ""
    
    // Group URLs by date
    private var groupedUrls: [(String, [URL])] {
        let grouped = Dictionary(grouping: urlsLocal) { url in
            extractDateString(from: url)
        }
        
        // Sort by date descending (newest first)
        return grouped.sorted { first, second in
            // Convert date strings back to comparable format
            let firstDate = dateFromString(first.key)
            let secondDate = dateFromString(second.key)
            return firstDate > secondDate
        }.map { (key, value) in
            // Sort URLs within each group by time descending
            let sortedUrls = value.sorted { url1, url2 in
                let time1 = extractTimeString(from: url1)
                let time2 = extractTimeString(from: url2)
                return time1 > time2
            }
            return (key, sortedUrls)
        }
    }
    
    private func extractDateString(from url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        
        // Try to extract date from Snip_YYYYMMDD_HHMMSS_xxx format
        if filename.hasPrefix("Snip_"),
           let dateRange = filename.range(of: "Snip_"),
           filename.count >= "Snip_YYYYMMDD".count {
            let afterPrefix = filename[dateRange.upperBound...]
            let dateString = String(afterPrefix.prefix(8)) // YYYYMMDD
            
            if dateString.count == 8 {
                return formatDateString(dateString)
            }
        }
        
        // Fallback: use file creation date (not modification date)
        do {
            let attrs = try url.resourceValues(forKeys: [.creationDateKey])  // Changed this
            if let date = attrs.creationDate {  // And this
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE, MMMM d"
                return formatter.string(from: date)
            }
        } catch {
            // Ignore errors
        }
        
        return "Unknown Date"
    }
    
    private func extractTimeString(from url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        
        // Try to extract time from Snip_YYYYMMDD_HHMMSS_xxx format
        if filename.hasPrefix("Snip_") {
            let components = filename.components(separatedBy: "_")
            if components.count >= 3 {
                return components[2] // HHMMSS
            }
        }
        
        return "000000" // Fallback for sorting
    }
    
    private func formatDateString(_ dateString: String) -> String {
        // Convert YYYYMMDD to readable format
        if dateString.count == 8 {
            let year = String(dateString.prefix(4))
            let monthString = String(dateString.dropFirst(4).prefix(2))
            let dayString = String(dateString.suffix(2))
            
            if let _ = Int(monthString), let _ = Int(dayString) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                
                if let date = formatter.date(from: "\(year)-\(monthString)-\(dayString)") {
                    let displayFormatter = DateFormatter()
                    displayFormatter.dateFormat = "EEEE, MMMM d"
                    return displayFormatter.string(from: date)
                }
            }
        }
        return dateString // Fallback
    }
    
    private func dateFromString(_ dateString: String) -> Date {
        // Convert formatted date string back to Date for sorting
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.date(from: dateString) ?? .distantPast
    }
    
    private func SnipsDirectoryFromSettings() -> URL? {
        if !saveDirectoryPath.isEmpty {
            return URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        }
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
    
    private func openSnipsInFinder() {
        guard let dir = SnipsDirectoryFromSettings() else { return }
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
    
    
    init(urls: [URL], onSelect: @escaping (URL) -> Void, onReload: @escaping () -> [URL], onVisibleDateChange: @escaping (String?) -> Void) {
        self.onSelect = onSelect
        self.onReload = onReload
        self.onVisibleDateChange = onVisibleDateChange
        _urlsLocal = State(initialValue: urls)
    }
    
    private struct SectionTopPreferenceKey: PreferenceKey {
        static var defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }
    
    private func updateVisibleDate(with positions: [String: CGFloat]) {
        // Pick the section whose top is closest to the top (>= 0 preferred), else the highest one
        // The coordinate space will be the ScrollView named "galleryScroll"
        let sorted = positions.sorted { a, b in
            let ay = a.value
            let by = b.value
            // Prefer non-negative mins that are closest to zero
            let aScore = ay >= 0 ? ay : abs(ay) + 10_000
            let bScore = by >= 0 ? by : abs(by) + 10_000
            return aScore < bScore
        }
        if let top = sorted.first?.key, top != currentVisibleDate {
            currentVisibleDate = top
            onVisibleDateChange(top)
        }
    }
    
    // Grid for each section
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 192), spacing: 8)]
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(groupedUrls, id: \.0) { dateString, urls in
                    VStack(alignment: .leading, spacing: 12) {
                        // Track this section's top position within the scroll coordinate space
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SectionTopPreferenceKey.self,
                                            value: [dateString: geo.frame(in: .named("galleryScroll")).minY])
                        }
                        .frame(height: 0)
                        // Date header
                        HStack {
                            Text(dateString)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            
                            Spacer()
                            
                            Text("\(urls.count) image\(urls.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        
                        // Images for this date
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(urls, id: \.self) { url in
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
                        .padding(.horizontal, 16)
                        
                        // Divider between dates (except for last)
                        if dateString != groupedUrls.last?.0 {
                            Divider()
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .coordinateSpace(name: "galleryScroll")
        .onPreferenceChange(SectionTopPreferenceKey.self) { positions in
            updateVisibleDate(with: positions)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    urlsLocal = onReload()
                    refreshTrigger = UUID()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Button {
                    openSnipsInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity,
               minHeight: 360, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .onDisappear { onVisibleDateChange(nil) }
        // Add this to ensure the view updates when presented again
        .onAppear {
            urlsLocal = onReload()
            refreshTrigger = UUID()
        }
    }
}
