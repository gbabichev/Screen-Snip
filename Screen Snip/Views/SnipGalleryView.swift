import SwiftUI

struct SnipGalleryView: View {
    @Binding var snipURLs: [URL]
    @Binding var selectedSnipURL: URL?
    @Binding var missingSnipURLs: Set<URL>
    var thumbnailsFocus: FocusState<Bool>.Binding
    @Binding var thumbnailRefreshTrigger: UUID
    var navigateToAdjacentThumbnail: (ContentView.NavigationDirection) -> Void
    var loadExistingSnips: () -> Void
    var openSnipsInFinder: () -> Void
    var openSnipsInGallery: () -> Void
    var deleteSnip: (URL) -> Void
    var onSelectSnip: (URL) -> Void
    var onMissingSnip: (URL) -> Void

    var body: some View {
        if !snipURLs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                headerControls
                thumbnailStrip
            }
            .padding(.top, 4)
            .background(.thinMaterial)
        }
    }

    private var headerControls: some View {
        HStack(spacing: 6) {
            Text("Snips")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: {
                loadExistingSnips()
                thumbnailRefreshTrigger = UUID()
            }) {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Refresh Snips")

            Button(action: openSnipsInFinder) {
                Image(systemName: "folder")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Open Snips in Finder")

            Button(action: openSnipsInGallery) {
                Image(systemName: "square.grid.2x2")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Open Snips Gallery")
        }
        .padding(.leading, 8)
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(snipURLs, id: \.self) { url in
                    ThumbnailView(
                        url: url,
                        selected: selectedSnipURL == url,
                        onDelete: { deleteSnip(url) },
                        width: 140,
                        height: 90,
                        refreshTrigger: thumbnailRefreshTrigger
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { handleSelection(of: url) }
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .focusable()
        .focused(thumbnailsFocus)
        .focusEffectDisabled()
        .background(
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { thumbnailsFocus.wrappedValue = true }
        )
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { keyPress in
            guard thumbnailsFocus.wrappedValue && !snipURLs.isEmpty else { return .ignored }
            if keyPress.key == .leftArrow {
                DispatchQueue.main.async { navigateToAdjacentThumbnail(.previous) }
                return .handled
            } else if keyPress.key == .rightArrow {
                DispatchQueue.main.async { navigateToAdjacentThumbnail(.next) }
                return .handled
            }
            return .ignored
        }
    }

    private func handleSelection(of url: URL) {
        thumbnailsFocus.wrappedValue = true

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            missingSnipURLs.insert(url)
            onMissingSnip(url)
            return
        }

        onSelectSnip(url)
    }
}
