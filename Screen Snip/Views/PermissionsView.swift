import SwiftUI
import ScreenCaptureKit
import ApplicationServices
import AppKit

struct PermissionsView: View {
    let needsAccessibility: Bool
    let needsScreenRecording: Bool
    let onContinue: () -> Void
    
    @State private var isTestingScreenRecording = false
    @State private var isTestingAccessibility = false
    
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
            
            // Permissions List with Action Buttons
            VStack(spacing: 16) {
                if needsAccessibility {
                    PermissionRowWithAction(
                        icon: "hand.point.up.left.fill",
                        title: "Accessibility",
                        description: "Required to capture screenshots with the global hotkey (⌘⇧2)",
                        status: .required,
                        buttonTitle: "Open System Settings",
                        isLoading: isTestingAccessibility
                    ) {
                        isTestingAccessibility = true
                        
                        onContinue()
                        
                        AXPromptCoordinator.shared.requestAXPromptOnly()
                        // The coordinator will call AppDelegate.shared.refreshPermissionStatus() after 2 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            isTestingAccessibility = false
                        }
                    }
                }
                
                if needsScreenRecording {
                    PermissionRowWithAction(
                        icon: "camera.viewfinder",
                        title: "Screen Recording",
                        description: "Required to capture screen content",
                        status: .required,
                        buttonTitle: "Allow",
                        isLoading: isTestingScreenRecording
                    ) {
                        onContinue()
                        testScreenRecordingPermission()
                    }
                }
            }
            .padding(.horizontal, 8)
            
            // Instructions
            VStack(spacing: 8) {
                Text("How it works:")
                    .font(.headline)
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 6) {
                    InstructionStep(
                        number: 1,
                        text: "Click the button above for each permission"
                    )
                    InstructionStep(
                        number: 2,
                        text: "For Accessibility - Click the '+' Sign and add Screen Snip. Make sure to flip the toggle!"
                    )
                    InstructionStep(
                        number: 3,
                        text: "For Screen Recording - Enable the Screen Recording toggle in System Settings."
                    )
                }
                .padding(.horizontal, 16)
            }
            
            // Continue Button
            Button("Continue") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func testScreenRecordingPermission() {
        isTestingScreenRecording = true
        
        Task {
            do {
                // Use ScreenCaptureKit to trigger the permission dialog
                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                
                if let display = availableContent.displays.first {
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = 100  // Small test capture
                    config.height = 100
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    
                    // This will show the permission dialog if needed
                    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                    try await stream.startCapture()
                    try await stream.stopCapture()
                }
                
                // If we got here, permission was likely granted
                await MainActor.run {
                    self.isTestingScreenRecording = false
                    AppDelegate.shared.refreshPermissionStatus()
                }
                
            } catch {
                print("Screen recording test failed: \(error)")
                await MainActor.run {
                    self.isTestingScreenRecording = false
                    AppDelegate.shared.refreshPermissionStatus()
                }
            }
        }
    }
}

struct PermissionRowWithAction: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let buttonTitle: String
    let isLoading: Bool
    let action: () -> Void
    
    enum PermissionStatus {
        case granted
        case required
    }
    
    var body: some View {
        VStack(spacing: 12) {
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
            
            // Action Button
            HStack {
                Spacer()
                Button(action: action) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "play.circle.fill")
                        }
                        Text(buttonTitle)
                            .lineLimit(1) // optional, prevents wrapping
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity) // makes content expand inside fixed frame
                }
                .frame(width: 250, height: 44) // fixed button size
                .buttonStyle(.bordered)
                .disabled(isLoading || status == .granted)
            }
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
