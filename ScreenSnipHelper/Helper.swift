//
//  Helper.swift
//  LoginItem-Helper
//
//  Created by George Babichev on 7/29/25.
//


import Cocoa // Import macOS UI framework

// MARK: - App Group constants
private let kAppGroupID = "group.com.georgebabichev.Screen-Snip" // ← ensure this matches your App Group exactly
private let kLaunchedByHelperKey = "launchedByHelper"

/// Attempts to locate the containing main app (…/MyApp.app) when this helper is embedded at
/// MyApp.app/Contents/Library/LoginItems/Helper.app
private func containingMainAppURL() -> URL? {
    var url = Bundle.main.bundleURL
    // Helper.app → LoginItems → Library → Contents → MyApp.app
    for _ in 0..<4 { url.deleteLastPathComponent() }
    // Sanity check that we ended at an .app bundle
    return FileManager.default.fileExists(atPath: url.path) && url.pathExtension == "app" ? url : nil
}


@MainActor
class LoginItemHelperApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🔧 Helper: Starting launch process")
        
        let mainAppBundleID = "com.georgebabichev.Screen-Snip"
        
        let config = NSWorkspace.OpenConfiguration()

        // Write App Group flag before launching main app
        if let defaults = UserDefaults(suiteName: kAppGroupID) {
            defaults.set(true, forKey: kLaunchedByHelperKey)
            defaults.synchronize()
            print("🔧 Helper: Wrote App Group flag: \(kLaunchedByHelperKey)=true in \(kAppGroupID)")
        } else {
            print("⚠️ Helper: Could not access App Group defaults for \(kAppGroupID). Check entitlements.")
        }

        // Prefer the containing app (Debug/Test builds) and fall back to installed app by bundle ID
        let resolvedMainAppURL = containingMainAppURL() ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainAppBundleID)

        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == mainAppBundleID }),
              let mainAppURL = resolvedMainAppURL else {
            print("🔧 Helper: Main app is already running or can't be found, terminating helper")
            NSApp.terminate(nil)
            return
        }

        print("🔧 Helper: Resolved main app bundle path: \(mainAppURL.path)")
        print("🔧 Helper: Launching main app at: \(mainAppURL)")
        print("🔧 Helper: Launching without CLI args/env; using App Group flag.")
        
        // Launch the main app
        NSWorkspace.shared.openApplication(at: mainAppURL, configuration: config) { app, error in
            if let error = error {
                print("🔧 Helper: Launch failed with error: \(error)")
            } else if let app = app {
                print("🔧 Helper: Successfully launched main app: \(app.bundleIdentifier ?? "unknown")")
            } else {
                print("🔧 Helper: Launch completed but no app or error returned")
            }
            
            Task { @MainActor in
                print("🔧 Helper: Terminating helper app")
                NSApp.terminate(nil)
            }
        }
        
        // Failsafe termination
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { // Increased to 3 seconds
            Task { @MainActor in
                print("🔧 Helper: Failsafe termination triggered")
                NSApp.terminate(nil)
            }
        }
    }
}
