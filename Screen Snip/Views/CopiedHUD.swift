//
//  CopiedHUD.swift
//  Screen Snip
//
//  Created by George Babichev on 9/15/25.
//

import SwiftUI

struct CopiedHUD: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
            Text("Copied to Clipboard")
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
        .shadow(radius: 6)
    }
}
