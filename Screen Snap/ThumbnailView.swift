//
//  ThumbnailView.swift
//  Screen Snap
//
//  Created by George Babichev on 9/12/25.
//

import SwiftUI

struct ThumbnailView: View {
    let url: URL
    let selected: Bool
    let onDelete: () -> Void
    let width: CGFloat
    let height: CGFloat

    @State private var image: NSImage?
    @State private var loadingID = UUID() // cancel token

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.low)
                    .antialiased(false)
                    .scaledToFill()
            } else {
                // Placeholder (keeps layout stable)
                Rectangle().fill(.quaternary)
                Image(systemName: "photo")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .background(.thinMaterial.opacity(0.0001)) // keeps hit-testing nice without visual weight
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onAppear { loadThumb() }
        .onChange(of: url) { _ in loadThumb() }
        .onDisappear { loadingID = UUID() } // cancels in-flight task
    }

    private func loadThumb() {
        // If cached, use immediately
        if let cached = ThumbnailCache.shared.image(for: url) {
            self.image = cached
            return
        }

        let myID = UUID()
        loadingID = myID

        // Generate off the main thread
        Task.detached(priority: .utility) {
            let thumb = await ThumbGen.makeThumbnail(url: url, targetSize: CGSize(width: width, height: height))
            await MainActor.run {
                guard loadingID == myID else { return } // canceled / cell reused
                if let thumb {
                    ThumbnailCache.shared.insert(thumb, for: url)
                    self.image = thumb
                } else {
                    self.image = nil
                }
            }
        }
    }
}
