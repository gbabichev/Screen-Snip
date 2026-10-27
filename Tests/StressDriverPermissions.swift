import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
enum StressDriverPermissions {
    static var settingsName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "Device Control and Data Access" : "Accessibility"
    }

    static func show(request: Bool) {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        print("Test driver: \(executable)")
        print("Terminal host: \(ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "not identified; use the entry named by macOS")")
        print("These checks concern the test driver/launcher, not Screen Snip's Screen Recording permission.")
        if request {
            // Ask macOS to present its own authorization UI. This never grants
            // access or changes a privacy setting on the user's behalf.
            if !AXIsProcessTrusted() {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
        }
        let events = CGPreflightPostEventAccess()
        let windowAccess = AXIsProcessTrusted()
        print("System event posting authorized: \(events)")
        print("\(settingsName) — window/UI access authorized: \(windowAccess)")
        if !events || !windowAccess {
            print("In System Settings → Privacy & Security → \(settingsName), enable the entry named in the macOS prompt.")
            print("When launched from Terminal, the responsible entry is normally Terminal; another terminal app has its own entry.")
            print("Authorizing Screen Snip alone does not authorize this external driver. If needed, restart your terminal app after granting access.")
            print("Run this script with --request-permissions to request access, then rerun --preflight. Neither flag sends test input events.")
        }
    }
}
