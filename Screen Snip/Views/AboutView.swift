//
//  AboutView.swift
//  Screen Snip
//


import SwiftUI

struct LiveAppIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var refreshID = UUID()
    
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .id(refreshID) // force SwiftUI to re-evaluate the image
            .frame(width: 72, height: 72)
            .onChange(of: colorScheme) { _,_ in
                // Let AppKit update its icon, then refresh the view
                DispatchQueue.main.async {
                    refreshID = UUID()
                }
            }
    }
}

struct AboutView: View {
    #if WEB_RELEASE
    @ObservedObject private var updateCenter = AppUpdateCenter.shared
    #endif

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                LiveAppIconView()

                Text("Screen Snip")
                    .font(.title.weight(.semibold))

                Text("Fast, powerful, and beautifully simple screenshots for Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }

            VStack(alignment: .leading, spacing: 6) {
                AboutRow(label: "Version", value: appVersion)
                AboutRow(label: "Build", value: appBuild)
                AboutRow(label: "Release Channel", value: releaseChannel)
                AboutRow(label: "Developer", value: "George Babichev")
                AboutRow(label: "Copyright", value: "© \(Calendar.current.component(.year, from: Date())) George Babichev")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )

            if let devPhoto = NSImage(named: "gbabichev") {
                HStack(spacing: 12) {
                    Image(nsImage: devPhoto)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("George Babichev")
                            .font(.headline)

                        Link(destination: URL(string: "https://georgebabichev.com")!) {
                            HStack(spacing: 4) {
                                Text("georgebabichev.com")
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.subheadline)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            #if WEB_RELEASE
            VStack(alignment: .center, spacing: 8) {
                Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath.circle") {
                    updateCenter.checkForUpdates(trigger: .manual)
                }
                .disabled(updateCenter.isChecking)

                if let lastStatusMessage = updateCenter.lastStatusMessage {
                    Text(lastStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            #endif
            
            Divider()

            Text("Screen Snip lets you quickly take screenshots, and open them in a simple editor with powerful tools.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .frame(width: 410)
    }
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }
    
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }

    private var releaseChannel: String {
        #if WEB_RELEASE
        return "Web Release"
        #else
        return "App Store"
        #endif
    }
}

private struct AboutRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 12)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AboutOverlayView: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack {
            // Match the subtle dimming used by system sheets instead of a full blurred wall.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            
            VStack {
                ZStack(alignment: .topTrailing) {
                    AboutView()
                        .frame(maxWidth: 410)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Color(NSColor.windowBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: Color.black.opacity(0.2), radius: 24, x: 0, y: 12)
                    
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .accessibilityLabel(Text("Close About"))
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .transition(.opacity)
        .onExitCommand {
            dismiss()
        }
    }
    
    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isPresented = false
        }
    }
}
