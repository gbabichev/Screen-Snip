//
//  PermissionsView.swift
//  Screen Snip
//
//  Created by George Babichev on 9/17/25.
//


import SwiftUI
//import AppKit

struct PermissionsView: View {
    let needsAccessibility: Bool
    let needsScreenRecording: Bool
    let onOpenPreferences: () -> Void
    let onContinue: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)
                
                Text("Permissions Required")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Screen Snip needs the following permissions to work properly:")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Permissions List
            VStack(spacing: 16) {
                if needsAccessibility {
                    PermissionRow(
                        icon: "hand.point.up.left.fill",
                        title: "Accessibility",
                        description: "Required to capture screenshots with the global hotkey (⌘⇧2)",
                        status: .required
                    )
                }
                
                if needsScreenRecording {
                    PermissionRow(
                        icon: "camera.viewfinder",
                        title: "Screen Recording",
                        description: "Required to capture screen content",
                        status: .required
                    )
                }
            }
            .padding(.horizontal, 8)
            
            // Instructions
            VStack(spacing: 8) {
                Text("What to do next:")
                    .font(.headline)
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 6) {
                    InstructionStep(
                        number: 1,
                        text: "Click 'Open System Preferences' below"
                    )
                    
                    if needsAccessibility {
                        InstructionStep(
                            number: 2,
                            text: "Go to Privacy & Security → Accessibility"
                        )
                        InstructionStep(
                            number: 3,
                            text: "Enable Screen Snip in the list"
                        )
                    }
                    
                    if needsScreenRecording {
                        let stepNumber = needsAccessibility ? 4 : 2
                        InstructionStep(
                            number: stepNumber,
                            text: "Go to Privacy & Security → Screen Recording"
                        )
                        InstructionStep(
                            number: stepNumber + 1,
                            text: "Enable Screen Snip in the list"
                        )
                    }
                    
                    let finalStep = (needsAccessibility ? 4 : 2) + (needsScreenRecording ? 2 : 0)
                    InstructionStep(
                        number: finalStep,
                        text: "Restart Screen Snip for all features to work"
                    )
                }
                .padding(.horizontal, 16)
            }
            
            // Action Buttons
            HStack(spacing: 12) {
                Button("Continue with Limited Features") {
                    onContinue()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                
                Button("Open System Preferences") {
                    onOpenPreferences()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    
    enum PermissionStatus {
        case granted
        case required
    }
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(status == .granted ? .green : .orange)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.medium)
                
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
            
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(status == .granted ? .green : .orange)
                .font(.title3)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct InstructionStep: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
    }
}
