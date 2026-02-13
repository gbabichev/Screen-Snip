//
//  BetaTag.swift
//  DHCP Test Tool
//
//  Created by George Babichev on 12/31/25.
//

import SwiftUI

struct BetaTag: View {
    var body: some View {
        Text("BETA")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.red)
            .textSelection(.disabled)
            .allowsHitTesting(false)
    }
}
