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
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .foregroundColor(.secondary)
            // Current year dynamically retrieved for copyright notice
            Text("© \(String(Calendar.current.component(.year, from: Date()))) George Babichev")
                .font(.footnote)
                .foregroundColor(.secondary)
            // Link to the author's GitHub profile for project reference
            Link("GitHub", destination: URL(string: "https://github.com/gbabichev/Screen-Snip")!)
                .font(.footnote)
                .foregroundColor(.accentColor)
        }
        .padding(40)
    }
}
