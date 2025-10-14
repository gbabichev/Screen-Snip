//
//  AboutView.swift
//  Mirror
//
//  Created by George Babichev on 7/21/25.
//

/*
 AboutView.swift provides the About screen for the Mirror app.
 It displays app branding, version info, copyright, and a link to the author’s GitHub.
 This view is intended to inform users about the app and its creator.
*/

import SwiftUI

struct LiveAppIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var refreshID = UUID()

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .id(refreshID) // force SwiftUI to re-evaluate the image
            .frame(width: 124, height: 124)
            .onChange(of: colorScheme) { _,_ in
                // Let AppKit update its icon, then refresh the view
                DispatchQueue.main.async {
                    refreshID = UUID()
                }
            }
    }
}

// MARK: - AboutView

/// A view presenting information about the app, including branding, version, copyright, and author link.
struct AboutView: View {
    var body: some View {
        // Main vertical stack arranging all elements with spacing
        VStack(spacing: 20) {

            HStack(spacing: 10) {
                Image("gbabichev")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(radius: 10)
                
                LiveAppIconView()
            }

            // App name displayed prominently
            Text("Screen Snip")
                .font(.title)
                .bold()
            
            Text("Simple Screenshot Utility")
                .font(.footnote)
            
            // App version fetched dynamically from Info.plist; fallback to "1.0"
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                .foregroundColor(.secondary)
            // Current year dynamically retrieved for copyright notice
            Link("© \(String(Calendar.current.component(.year, from: Date()))) George Babichev", destination: URL(string: "https://georgebabichev.com")!)
                .font(.footnote)
                .foregroundColor(.accentColor)
            // Link to the author's GitHub profile for project reference
            Link("Website", destination: URL(string: "https://gbabichev.github.io/Screen-Snip/")!)
                .font(.footnote)
                .foregroundColor(.accentColor)
        }
        .padding(40)
    }
}

struct AboutOverlayView: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }
            
            VStack {
                ZStack(alignment: .topTrailing) {
                    AboutView()
                        .frame(maxWidth: 420)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(.regularMaterial)
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
