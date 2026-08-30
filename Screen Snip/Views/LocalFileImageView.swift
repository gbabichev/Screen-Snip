import AppKit
import SwiftUI

/// Loads an image from disk without routing a local file URL through URLSession.
///
/// `AsyncImage` uses URLSession even for `file://` URLs, which can leave
/// CFNetworkDownload temporary files behind. Reading the file data directly
/// keeps local image loading out of CFNetwork while preserving asynchronous UI.
struct LocalFileImageView: View {
    let url: URL
    let reloadToken: UUID
    let width: CGFloat
    let height: CGFloat

    @State private var image: NSImage?
    @State private var didFail = false

    private struct LoadIdentity: Equatable {
        let url: URL
        let reloadToken: UUID
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
            } else if didFail {
                Color.secondary.opacity(0.1)
                    .frame(width: width, height: height)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("Failed to load image")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            } else {
                ProgressView()
                    .frame(width: width, height: height)
            }
        }
        .task(id: LoadIdentity(url: url.standardizedFileURL, reloadToken: reloadToken)) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        didFail = false

        let sourceURL = url.standardizedFileURL
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: sourceURL, options: .mappedIfSafe)
        }.value

        guard !Task.isCancelled else { return }
        guard let data, let loadedImage = NSImage(data: data) else {
            didFail = true
            return
        }

        image = loadedImage
    }
}
