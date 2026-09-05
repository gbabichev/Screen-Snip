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
    private var windowController: NSWindowController?
    private var closeHandler: WindowCloseHandler?
    
    private func makeGalleryRootContent(
        urls: [URL],
        onSelect: @escaping (URL) -> Void,
        onReload: @escaping () async -> [URL],
        onVisibleDateChange: @escaping (String?) -> Void
    ) -> AnyView {
        let content = GalleryView(
            urls: urls,
            onSelect: onSelect,
            onReload: onReload,
            onVisibleDateChange: onVisibleDateChange
        )
        #if DEBUG
        return AnyView(
            content.overlay(alignment: .bottomTrailing) {
                BetaTag()
                    .padding(12)
            }
        )
        #else
        return AnyView(content)
        #endif
    }
    
    func present(urls: [URL], onSelect: @escaping (URL) -> Void, onReload: @escaping () async -> [URL]) {
        // If already visible, just bring to front and update content
        if let win = window {
            
            // Always create a new hosting controller with fresh data to ensure SwiftUI updates
            let content = makeGalleryRootContent(
                urls: urls,
                onSelect: onSelect,
                onReload: onReload,
                onVisibleDateChange: { [weak win] date in
                    win?.title = date.map { "Snip Gallery — \($0)" } ?? "Snip Gallery"
                }
            )
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        let content = makeGalleryRootContent(
            urls: urls,
            onSelect: onSelect,
            onReload: onReload,
            onVisibleDateChange: { [weak win] date in
                win?.title = date.map { "Snip Gallery — \($0)" } ?? "Snip Gallery"
            }
        )
        let hosting = NSHostingController(rootView: content)
        
        win.title = "Snip Gallery"
        win.titleVisibility = .visible
        win.titlebarAppearsTransparent = false
        win.titlebarSeparatorStyle = .automatic
        win.toolbarStyle = .unified
        win.isMovableByWindowBackground = false
        win.tabbingMode = .disallowed
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 900, height: 600)
        win.contentViewController = hosting
        
        // Create controller and set up autosave through the controller
        let controller = NSWindowController(window: win)
        let autosaveName = "SnipGalleryWindowV2"
        controller.windowFrameAutosaveName = autosaveName
        
        self.window = win
        self.windowController = controller
        
        // Set up close handler
        let closeHandler = WindowCloseHandler() { [weak self] in
            self?.window = nil
            self?.windowController = nil
            self?.closeHandler = nil
        }
        self.closeHandler = closeHandler
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
        windowController = nil
        closeHandler = nil
    }
}

/// SwiftUI gallery view: scrollable grid of thumbnails that calls `onSelect(url)` when tapped.
struct GalleryView: View {
    private struct TrashedItem: Identifiable {
        let id = UUID()
        let originalURL: URL
        let trashedURL: URL
    }

    let onSelect: (URL) -> Void
    let onReload: () async -> [URL]
    let onVisibleDateChange: (String?) -> Void
    @State private var urlsLocal: [URL]
    @State private var selectedUrl: URL?
    @State private var refreshTrigger = UUID()
    @State private var currentVisibleDate: String? = nil
    @State private var isReloading = false
    @State private var reloadRequestedWhileLoading = false
    @State private var isSelecting = false
    @State private var selectedURLs: Set<URL> = []
    @State private var pendingDeletion: [TrashedItem] = []
    @State private var deletionNoticeID = UUID()
    
    @AppStorage("saveDirectoryPath") private var saveDirectoryPath: String = ""
    
    // Group URLs by date (day), keeping a real Date for sorting across years.
    private var groupedUrls: [(Date, String, [URL])] {
        let dated = urlsLocal.map { url in
            (url, extractCaptureDate(from: url))
        }
        let grouped = Dictionary(grouping: dated) { item in
            Calendar.current.startOfDay(for: item.1)
        }
        
        // Sort by date descending (newest first)
        return grouped.sorted { first, second in
            first.key > second.key
        }.map { (dayStart, items) in
            let label = displayDateString(from: dayStart)
            let sortedUrls = items.sorted { $0.1 > $1.1 }.map { $0.0 }
            return (dayStart, label, sortedUrls)
        }
    }
    
    private func extractCaptureDate(from url: URL) -> Date {
        let filename = url.deletingPathExtension().lastPathComponent
        
        if filename.hasPrefix("Snip_") {
            let components = filename.split(separator: "_")
            if components.count >= 3 {
                let dateTimeString = "\(components[1])_\(components[2])"
                if let date = Self.snipFilenameDateTimeFormatter.date(from: dateTimeString) {
                    return date
                }
            }
            if components.count >= 2 {
                let dateString = String(components[1])
                if let date = Self.snipFilenameDateFormatter.date(from: dateString) {
                    return date
                }
            }
        }
        
        if let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
            return date
        }
        
        return .distantPast
    }
    
    private func displayDateString(from date: Date) -> String {
        Self.displayDateFormatter.string(from: date)
    }

    private static let snipFilenameDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
    
    private static let snipFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd"
        return formatter
    }()
    
    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter
    }()
    
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
    
    private func deleteFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let fileManager = FileManager.default
        var trashedItems: [TrashedItem] = []
        var deletedURLs = Set<URL>()

        for url in urls {
            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                deletedURLs.insert(url)
                if let resultingURL {
                    trashedItems.append(
                        TrashedItem(originalURL: url, trashedURL: resultingURL as URL)
                    )
                }
            } catch {
                print("Failed to delete file: \(error)")
            }
        }

        guard !deletedURLs.isEmpty else { return }

        withAnimation {
            urlsLocal.removeAll { deletedURLs.contains($0) }
            selectedURLs.subtract(deletedURLs)
            if let selectedUrl, deletedURLs.contains(selectedUrl) {
                self.selectedUrl = nil
            }
            pendingDeletion = trashedItems
            isSelecting = false
        }

        let noticeID = UUID()
        deletionNoticeID = noticeID
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard deletionNoticeID == noticeID else { return }
            withAnimation { pendingDeletion.removeAll() }
        }
    }

    private func undoLastDeletion() {
        let itemsToRestore = pendingDeletion
        guard !itemsToRestore.isEmpty else { return }

        deletionNoticeID = UUID()
        let fileManager = FileManager.default
        var restoredURLs: [URL] = []
        var failedItems: [TrashedItem] = []

        for item in itemsToRestore {
            let destination = availableRestoreURL(for: item.originalURL, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: item.trashedURL, to: destination)
                restoredURLs.append(destination)
            } catch {
                print("Failed to restore deleted file: \(error)")
                failedItems.append(item)
            }
        }

        withAnimation {
            urlsLocal.append(contentsOf: restoredURLs)
            pendingDeletion = failedItems
        }
        refreshTrigger = UUID()
    }

    private func availableRestoreURL(for originalURL: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: originalURL.path) else { return originalURL }

        let directory = originalURL.deletingLastPathComponent()
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let pathExtension = originalURL.pathExtension
        var suffix = 1

        while true {
            let restoredName = suffix == 1 ? "\(baseName) restored" : "\(baseName) restored \(suffix)"
            let candidate = directory
                .appendingPathComponent(restoredName)
                .appendingPathExtension(pathExtension)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func toggleSelection(of url: URL) {
        if selectedURLs.contains(url) {
            selectedURLs.remove(url)
        } else {
            selectedURLs.insert(url)
        }
    }
    
    
    init(urls: [URL], onSelect: @escaping (URL) -> Void, onReload: @escaping () async -> [URL], onVisibleDateChange: @escaping (String?) -> Void) {
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
        let top = positions.min { first, second in
            let firstScore = first.value >= 0 ? first.value : abs(first.value) + 10_000
            let secondScore = second.value >= 0 ? second.value : abs(second.value) + 10_000
            return firstScore < secondScore
        }?.key
        if let top, top != currentVisibleDate {
            currentVisibleDate = top
            onVisibleDateChange(top)
        }
    }
    
    // Grid for each section
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 192), spacing: 8)]
    }

    private func reload() async {
        if isReloading {
            reloadRequestedWhileLoading = true
            return
        }

        isReloading = true
        repeat {
            reloadRequestedWhileLoading = false
            let refreshedURLs = await onReload()
            guard !Task.isCancelled else {
                isReloading = false
                return
            }
            urlsLocal = refreshedURLs
            refreshTrigger = UUID()
        } while reloadRequestedWhileLoading
        isReloading = false
    }

    private func startWatchingSnipsDirectory() {
        guard let directory = SnipsDirectoryFromSettings() else { return }
        SnipDirectoryWatcher.shared.watch(directory: directory)
    }
    
    var body: some View {
        let groups = groupedUrls

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(groups, id: \.0) { date, dateString, urls in
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
                                    selected: isSelecting ? selectedURLs.contains(url) : selectedUrl == url,
                                    onDelete: { deleteFiles([url]) },
                                    width: 180,
                                    height: 120,
                                    refreshTrigger: refreshTrigger,
                                    showsDeleteButton: !isSelecting,
                                    showsSelectionBadge: isSelecting
                                )
                                .onTapGesture {
                                    if isSelecting {
                                        toggleSelection(of: url)
                                    } else {
                                        selectedUrl = url
                                        onSelect(url)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        
                        // Divider between dates (except for last)
                        if date != groups.last?.0 {
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
                    openSnipsInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if isSelecting {
                    Button(role: .destructive) {
                        deleteFiles(Array(selectedURLs))
                    } label: {
                        Label(
                            selectedURLs.isEmpty ? "Delete" : "Delete \(selectedURLs.count)",
                            systemImage: "trash"
                        )
                    }
                    .disabled(selectedURLs.isEmpty)

                    Button("Done") {
                        withAnimation {
                            isSelecting = false
                            selectedURLs.removeAll()
                        }
                    }
                } else {
                    Button {
                        withAnimation {
                            isSelecting = true
                            selectedURLs.removeAll()
                            selectedUrl = nil
                        }
                    } label: {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity,
               minHeight: 360, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if !pendingDeletion.isEmpty {
                HStack(spacing: 12) {
                    Text(
                        pendingDeletion.count == 1
                            ? "Moved 1 snip to Trash"
                            : "Moved \(pendingDeletion.count) snips to Trash"
                    )
                    .font(.callout)

                    Button("Undo", action: undoLastDeletion)
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDisappear { onVisibleDateChange(nil) }
        .onChange(of: saveDirectoryPath) { _, _ in
            startWatchingSnipsDirectory()
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .snipDirectoryDidChange)) { notification in
            guard let changedDirectory = notification.object as? URL,
                  let galleryDirectory = SnipsDirectoryFromSettings(),
                  changedDirectory.standardizedFileURL == galleryDirectory.standardizedFileURL else {
                return
            }
            Task { await reload() }
        }
        // Display the recent in-memory thumbnails immediately, then replace
        // them with one complete directory scan performed off the main thread.
        .task {
            startWatchingSnipsDirectory()
            await reload()
        }
    }
}

enum GalleryFileLoader {
    nonisolated static func loadURLs(from directory: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let supportedExtensions = Set(["png", "jpg", "jpeg", "heic"])
            let fileManager = FileManager.default
            let urls: [URL]

            do {
                urls = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.creationDateKey],
                    options: [.skipsHiddenFiles]
                ).filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            } catch {
                return []
            }

            let dateTimeFormatter = DateFormatter()
            dateTimeFormatter.calendar = Calendar(identifier: .gregorian)
            dateTimeFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateTimeFormatter.timeZone = .current
            dateTimeFormatter.dateFormat = "yyyyMMdd_HHmmss"

            let dateFormatter = DateFormatter()
            dateFormatter.calendar = Calendar(identifier: .gregorian)
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = .current
            dateFormatter.dateFormat = "yyyyMMdd"

            func captureDate(for url: URL) -> Date {
                let filename = url.deletingPathExtension().lastPathComponent
                if filename.hasPrefix("Snip_") {
                    let components = filename.split(separator: "_")
                    if components.count >= 3,
                       let date = dateTimeFormatter.date(from: "\(components[1])_\(components[2])") {
                        return date
                    }
                    if components.count >= 2,
                       let date = dateFormatter.date(from: String(components[1])) {
                        return date
                    }
                }
                return (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            }

            var seenPaths = Set<String>()
            return urls
                .map { ($0.standardizedFileURL, captureDate(for: $0)) }
                .sorted { $0.1 > $1.1 }
                .compactMap { url, _ in
                    seenPaths.insert(url.path).inserted ? url : nil
                }
        }.value
    }
}
