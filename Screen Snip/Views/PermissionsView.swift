import SwiftUI
import AppKit
import CoreGraphics

struct PermissionsView: View {
    let needsScreenRecording: Bool
    let onContinue: () -> Void
    
    @State private var isTestingScreenRecording = false
    @State private var didRequestScreenRecordingPermission = false
    
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
                
                Text("Screen Snip needs Screen Recording permission to capture your screen:")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Permissions List with Action Buttons
            VStack(spacing: 16) {
                
                if needsScreenRecording {
                    PermissionRowWithAction(
                        icon: "camera.viewfinder",
                        title: "Screen Recording",
                        description: "Required to capture screen content",
                        status: .required,
                        buttonTitle: didRequestScreenRecordingPermission ? "Open System Settings" : "Allow",
                        isLoading: isTestingScreenRecording
                    ) {
                        handleScreenRecordingPermission()
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
                        text: didRequestScreenRecordingPermission
                            ? "Click Open System Settings above."
                            : "Click Allow above to request access from macOS."
                    )
                    InstructionStep(number: 2, text: "Enable Screen Recording for Screen Snip, then use macOS’s Quit & Reopen button if prompted.")
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
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
    
    private func handleScreenRecordingPermission() {
        if CGPreflightScreenCaptureAccess() {
            AppDelegate.shared.refreshPermissionStatus()
            onContinue()
            return
        }

        // A previously denied process is not prompted again. For this presentation,
        // remember that the native request has been made so the next attempt goes
        // straight to Settings. This intentionally resets when the sheet is reopened
        // so a rebuilt or newly signed app gets a fresh native registration attempt.
        if didRequestScreenRecordingPermission {
            openScreenRecordingSettings()
            onContinue()
            return
        }

        isTestingScreenRecording = true
        didRequestScreenRecordingPermission = true

        // This is the system-supported permission request. Unlike starting a
        // temporary SCStream, it behaves consistently for sandboxed builds.
        let granted = CGRequestScreenCaptureAccess()

        isTestingScreenRecording = false
        AppDelegate.shared.refreshPermissionStatus()

        if granted {
            onContinue()
        }
    }

    private func openScreenRecordingSettings() {
        // macOS does not expose a dedicated public API for this privacy pane.
        // The preference URL is the standard route used by Mac apps, with a
        // generic System Settings fallback in case Apple changes the route.
        if let privacyPaneURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ), NSWorkspace.shared.open(privacyPaneURL) {
            return
        }

        let systemSettingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.openApplication(
            at: systemSettingsURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
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
