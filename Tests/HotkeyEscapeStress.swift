import AppKit
import ApplicationServices
import Foundation

// External end-to-end driver. It never calls Screen Snip's capture/cancel code.
// Run --preflight first; event posting requires existing macOS authorization.
@MainActor
@main
struct HotkeyEscapeStress {
    struct Window: Codable {
        let id: Int
        let layer: Int
        let title: String
        let width: Double
        let height: Double
        var isEditor: Bool { layer == 0 && width >= 300 && height >= 200 }
        var isSelection: Bool { layer == Int(NSWindow.Level.screenSaver.rawValue) }
    }
    struct Trial: Codable {
        let iteration: Int
        let startedAt: String
        let initialEditorVisible: Bool
        let initialWindows: [Window]
        let hotkeyToOverlayMS: Double
        let escapeDelayMS: Int
        let overlayDismissed: Bool
        let editorReopened: Bool
        let firstReopenMS: Double?
        let finalWindows: [Window]
    }
    static func write(_ value: String) {
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }
    static func windows(pid: pid_t) -> [Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return Window(
                id: (row[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1,
                layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                title: row[kCGWindowName as String] as? String ?? "",
                width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            )
        }
    }
    static func closeEditor(pid: pid_t) throws {
        let application = AXUIElementCreateApplication(pid)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let appWindows = rawWindows as? [AXUIElement] else {
            throw DriverError.precondition("could not inspect app windows before closing the editor")
        }
        for window in appWindows {
            var rawSize: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
                  let rawSize, CFGetTypeID(rawSize) == AXValueGetTypeID() else { continue }
            var size = CGSize.zero
            guard AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
                  size.width >= 300, size.height >= 200 else { continue }
            var rawCloseButton: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &rawCloseButton) == .success,
                  let rawCloseButton, CFGetTypeID(rawCloseButton) == AXUIElementGetTypeID(),
                  AXUIElementPerformAction(rawCloseButton as! AXUIElement, kAXPressAction as CFString) == .success else {
                throw DriverError.precondition("could not close the editor via its actual close button")
            }
        }
    }
    static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
    static func until(timeout: Double, condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if condition() { return true }
            await pause(0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }
    static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
    static func captureHotkey() async {
        key(55, down: true, flags: .maskCommand)
        key(56, down: true, flags: [.maskCommand, .maskShift])
        key(19, down: true, flags: [.maskCommand, .maskShift])
        await pause(0.03)
        key(19, down: false, flags: [.maskCommand, .maskShift])
        key(56, down: false, flags: .maskCommand)
        key(55, down: false)
    }
    static func escape() async {
        key(53, down: true)
        await pause(0.02)
        key(53, down: false)
    }
    static func main() async {
        let args = CommandLine.arguments
        let authorized = CGPreflightPostEventAccess()
        if args.contains("--preflight") || args.contains("--request-permissions") {
            StressDriverPermissions.show(request: args.contains("--request-permissions"))
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.contains("Screen-Snip") == true {
                write("Running app: \(app.bundleURL?.path ?? "unknown") pid=\(app.processIdentifier)")
                let snapshot = try! JSONEncoder().encode(windows(pid: app.processIdentifier))
                write(String(decoding: snapshot, as: UTF8.self))
            }
            return
        }
        guard args.count >= 4, let count = Int(args[2]), count > 0 else {
            write("Usage: HotkeyEscapeStress APP_PATH ITERATIONS OUTPUT_DIRECTORY [BASELINE_SHA]")
            exit(2)
        }
        guard authorized, AXIsProcessTrusted() else {
            StressDriverPermissions.show(request: false)
            write("BLOCKED: the test driver/launcher lacks required authorization. No events sent.")
            exit(2)
        }
        let appURL = URL(fileURLWithPath: args[1])
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        let baseline = args.count > 4 ? args[4] : "unspecified"
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let logURL = output.appendingPathComponent("trials.jsonl")
            guard !FileManager.default.fileExists(atPath: logURL.path) else {
                write("BLOCKED: output already contains trials.jsonl; choose a fresh directory.")
                exit(2)
            }
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            guard app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == appURL.resolvingSymlinksInPath().standardizedFileURL else {
                write("BLOCKED: macOS resolved a different app bundle: \(app.bundleURL?.path ?? "unknown")")
                exit(2)
            }
            let pid = app.processIdentifier
            // Let launch-time activation and permission refresh finish before
            // closing the initial editor and beginning measured trials.
            await pause(1.0)
            guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
                write("BLOCKED: Finder must be running for the desktop/background precondition.")
                exit(2)
            }
            write("Baseline \(baseline); app=\(appURL.path); pid=\(pid); requested=\(count)")
            var trials: [Trial] = []
            let delays = [0, 25, 75, 150, 300]
            for iteration in 1...count {
                // The app stays running, but its editor must be CLOSED before
                // the hotkey. Never reopen it as part of trial setup.
                if windows(pid: pid).contains(where: \.isEditor) {
                    try closeEditor(pid: pid)
                }
                guard await until(timeout: 3, condition: { !windows(pid: pid).contains(where: \.isEditor) }) else {
                    throw DriverError.precondition("editor not closed before trial \(iteration)")
                }
                finder.activate(options: [])
                guard await until(timeout: 2, condition: {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier
                }) else { throw DriverError.precondition("Finder did not become foreground") }
                await pause(0.1)
                let initial = windows(pid: pid)
                guard !initial.contains(where: \.isEditor), !initial.contains(where: \.isSelection) else {
                    throw DriverError.precondition("invalid starting windows at trial \(iteration)")
                }
                let startedAt = ISO8601DateFormatter().string(from: Date())
                if iteration == 1 {
                    write("Verified pre-hotkey windows: " + String(decoding: try encoder.encode(initial), as: UTF8.self))
                }
                let captureStart = ProcessInfo.processInfo.systemUptime
                await captureHotkey()
                guard await until(timeout: 5, condition: { windows(pid: pid).contains(where: \.isSelection) }) else {
                    // An injected shortcut that never opens the overlay is NOT
                    // a successful capture/cancel trial.
                    write("Windows after missing overlay: " + String(decoding: try encoder.encode(windows(pid: pid)), as: UTF8.self))
                    throw DriverError.precondition("actual global hotkey did not produce an overlay at trial \(iteration)")
                }
                let latency = (ProcessInfo.processInfo.systemUptime - captureStart) * 1000
                guard !windows(pid: pid).contains(where: \.isEditor) else {
                    await escape()
                    throw DriverError.precondition("editor remained on screen during capture; verify Hide Screen Snip During Capture")
                }
                let delay = delays[(iteration - 1) % delays.count]
                await pause(Double(delay) / 1000)
                let cancelStart = ProcessInfo.processInfo.systemUptime
                await escape()
                var dismissed = false
                var firstReopen: Double?
                repeat {
                    let current = windows(pid: pid)
                    if !current.contains(where: \.isSelection) { dismissed = true }
                    if current.contains(where: \.isEditor), firstReopen == nil {
                        firstReopen = (ProcessInfo.processInfo.systemUptime - cancelStart) * 1000
                    }
                    await pause(0.02)
                } while ProcessInfo.processInfo.systemUptime - cancelStart < 1.5
                let trial = Trial(
                    iteration: iteration, startedAt: startedAt,
                    initialEditorVisible: initial.contains(where: \.isEditor), initialWindows: initial,
                    hotkeyToOverlayMS: latency, escapeDelayMS: delay, overlayDismissed: dismissed,
                    editorReopened: firstReopen != nil, firstReopenMS: firstReopen, finalWindows: windows(pid: pid)
                )
                trials.append(trial)
                try log.write(contentsOf: encoder.encode(trial) + Data([10]))
                try log.synchronize()
                if !dismissed {
                    throw DriverError.precondition("Escape did not dismiss the overlay at trial \(iteration)")
                }
                if iteration <= 5 || iteration % 10 == 0 || iteration == count {
                    let failures = trials.filter(\.editorReopened).count
                    write("Progress \(iteration)/\(count): confirmed overlays=\(trials.count), editor reopens=\(failures)")
                }
            }
            let failures = trials.filter(\.editorReopened).count
            let summary: [String: Any] = [
                "baseline": baseline, "appPath": appURL.path, "iterations": trials.count,
                "confirmedCaptureOverlays": trials.count, "editorReopened": failures,
                "overlayDismissals": trials.filter(\.overlayDismissed).count,
                "observationSecondsPerTrial": 1.5, "escapeDelayMilliseconds": delays,
                "startingState": "editor CLOSED; app running; Finder foreground; hide-during-capture enabled",
                "input": "system CGEvent hotkey Cmd+Shift+2 followed by Escape",
                "observer": "read-only CGWindowListCopyWindowInfo sampled every approximately 20 ms"
            ]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("summary.json"))
            write("COMPLETE: \(trials.count) actual hotkey/overlay/Escape cycles; editor reopened \(failures) times.")
        } catch {
            write("BLOCKED/INVALID RUN: \(error)")
            exit(2)
        }
    }
    enum DriverError: Error { case precondition(String) }
}
