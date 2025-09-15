import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ImageIO

struct ThumbnailView: View {
    let url: URL
    let selected: Bool
    let onDelete: () -> Void
    let width: CGFloat
    let height: CGFloat
    let refreshTrigger: UUID

    @State private var image: NSImage?
    @State private var loadingID = UUID()
    @State private var isHovering = false // Add hover state

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Main thumbnail content
            ZStack {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.low)
                        .antialiased(false)
                        .scaledToFill()
                        .frame(width: width, height: height)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "photo")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: width, height: height)
                }
            }
            .clipped()
            .background(.thinMaterial.opacity(0.0001))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Hover delete button overlay, aligned to the thumbnail's top-right
            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white, .red)
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .frame(width: width, height: height, alignment: .center)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.background.opacity(0.0001)) // keep layout stable without visual change
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .shadow(radius: isHovering ? 2 : 0) // subtle depth without affecting layout
        .padding(6) // << uniform outer spacing between tiles
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onAppear { loadThumb() }
        .onChange(of: url) { _,_ in loadThumb() }
        .onChange(of: refreshTrigger) { _,_ in loadThumb() }
        .onDisappear { loadingID = UUID() }
    }

    private func loadThumb() {
        let myID = UUID()
        loadingID = myID

        Task.detached(priority: .utility) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: width, height: height),
                scale: await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 },
                representationTypes: .thumbnail
            )
            
            do {
                let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                let nsImage = thumbnail.nsImage
                
                await MainActor.run {
                    guard loadingID == myID else { return }
                    self.image = nsImage
                }
            } catch {
                await MainActor.run {
                    guard loadingID == myID else { return }
                    self.image = nil
                }
            }
        }
    }
}
