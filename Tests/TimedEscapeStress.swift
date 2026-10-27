import AppKit
import ApplicationServices
import Foundation

// External end-to-end driver. It never calls Screen Snip's capture/cancel code.
// Run --preflight first; event posting requires existing macOS authorization.
@MainActor
@main
struct TimedEscapeStress {
    struct Window: Codable {
        let id: Int
        let layer: Int
        let title: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var isEditor: Bool { layer == 0 && width >= 300 && height >= 200 }
        var isSelection: Bool { layer == Int(NSWindow.Level.screenSaver.rawValue) }
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
                x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
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
    static var heldMousePosition: CGPoint?
    static func mouse(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)!
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
        if type == .leftMouseDown || type == .leftMouseDragged { heldMousePosition = point }
        if type == .leftMouseUp { heldMousePosition = nil }
    }
    static func sizeLabel(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var budget = 160
        func search(_ element: AXUIElement, depth: Int) -> String? {
            guard depth < 10, budget > 0 else { return nil }
            budget -= 1
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let text = value as? String,
                   text.range(of: #"\b\d{2,4}\s*×\s*\d{2,4}\b"#, options: .regularExpression) != nil {
                    return text
                }
            }
            var rawChildren: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
               let children = rawChildren as? [AXUIElement] {
                for child in children {
                    if let label = search(child, depth: depth + 1) { return label }
                }
            }
            return nil
        }
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let appWindows = rawWindows as? [AXUIElement] else { return nil }
        for window in appWindows {
            if let label = search(window, depth: 0) { return label }
        }
        return nil
    }
    static func snapshot(_ value: [Window]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    final class Observation {
        let pid: pid_t
        let start: Double
        var firstOverlayMS: Double?
        var firstEditorMS: Double?
        init(pid: pid_t, start: Double) { self.pid = pid; self.start = start }
        @discardableResult func sample() -> [Window] {
            let current = windows(pid: pid)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            if firstOverlayMS == nil, current.contains(where: \.isSelection) { firstOverlayMS = elapsed }
            if firstEditorMS == nil, current.contains(where: \.isEditor) { firstEditorMS = elapsed }
            return current
        }
        func watch(until deadline: Double) async {
            repeat {
                sample()
                await pause(0.02)
            } while ProcessInfo.processInfo.systemUptime < deadline
            sample()
        }
    }
    static func imageFiles(in directories: [URL]) throws -> Set<String> {
        var names = Set<String>()
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where ["jpg", "jpeg", "png", "heic", "heif"].contains(file.pathExtension.lowercased()) {
                names.insert(file.path)
            }
        }
        return names
    }
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--preflight") || args.contains("--request-permissions") {
            StressDriverPermissions.show(request: args.contains("--request-permissions"))
            return
        }
        guard args.count >= 5, ["startup", "drag"].contains(args[2]), let count = Int(args[3]), count > 0 else {
            write("Usage: TimedEscapeStress APP_PATH startup|drag ITERATIONS OUTPUT_DIRECTORY [BASELINE_SHA]")
            exit(2)
        }
        guard CGPreflightPostEventAccess(), AXIsProcessTrusted() else {
            StressDriverPermissions.show(request: false)
            write("BLOCKED: the test driver/launcher lacks required authorization. No events sent.")
            exit(2)
        }
        defer { if let point = heldMousePosition { mouse(.leftMouseUp, at: point) } }
        let appURL = URL(fileURLWithPath: args[1])
        let scenario = args[2]
        let output = URL(fileURLWithPath: args[4], isDirectory: true)
        let baseline = args.count > 5 ? args[5] : "unspecified"
        let delays = scenario == "startup" ? [40, 75, 125, 200, 300, 400, 475, 550] : [0, 25, 75, 150, 300]
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let logURL = output.appendingPathComponent("trials.jsonl")
            guard !FileManager.default.fileExists(atPath: logURL.path) else {
                throw DriverError.precondition("choose a fresh output directory")
            }
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            guard app.bundleURL?.resolvingSymlinksInPath() == appURL.resolvingSymlinksInPath() else {
                throw DriverError.precondition("macOS launched a different app bundle")
            }
            let pid = app.processIdentifier
            await pause(1)
            guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
                throw DriverError.precondition("Finder must be running")
            }
            var saveDirectories = [FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Screen Snip", isDirectory: true)]
            if let id = app.bundleIdentifier,
               let custom = UserDefaults(suiteName: id)?.string(forKey: "saveDirectoryPath"), !custom.isEmpty {
                saveDirectories.append(URL(fileURLWithPath: custom, isDirectory: true))
            }
            var records: [[String: Any]] = []
            write("Baseline \(baseline); scenario=\(scenario); pid=\(pid); requested=\(count)")
            for iteration in 1...count {
                guard !app.isTerminated else { throw DriverError.precondition("app terminated") }
                if windows(pid: pid).contains(where: \.isEditor) { try closeEditor(pid: pid) }
                guard await until(timeout: 3, condition: { !windows(pid: pid).contains(where: \.isEditor) }) else {
                    throw DriverError.precondition("editor not closed before trial")
                }
                finder.activate(options: [])
                guard await until(timeout: 2, condition: {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier
                }) else { throw DriverError.precondition("Finder did not become foreground") }
                await pause(0.1)
                let initial = windows(pid: pid)
                guard !initial.contains(where: \.isEditor), !initial.contains(where: \.isSelection) else {
                    throw DriverError.precondition("invalid starting windows")
                }
                let existingImages = try imageFiles(in: saveDirectories)
                let startedAt = ISO8601DateFormatter().string(from: Date())
                let start = ProcessInfo.processInfo.systemUptime
                let observation = Observation(pid: pid, start: start)
                let delay = delays[(iteration - 1) % delays.count]
                var record: [String: Any] = [
                    "iteration": iteration, "scenario": scenario, "startedAt": startedAt,
                    "initialEditorVisible": false, "initialWindows": try snapshot(initial), "requestedDelayMS": delay
                ]
                await captureHotkey()
                if scenario == "startup" {
                    await observation.watch(until: start + Double(delay) / 1000)
                    record["overlayVisibleAtEscape"] = windows(pid: pid).contains(where: \.isSelection)
                    record["escapeFromHotkeyMS"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    await escape()
                    await observation.watch(until: ProcessInfo.processInfo.systemUptime + 1.5)
                    let stillPresent = windows(pid: pid).contains(where: \.isSelection)
                    record["overlayRemainedAfterFirstEscape"] = stillPresent
                    record["cleanupRequired"] = stillPresent
                    if stillPresent {
                        await escape()
                        await observation.watch(until: ProcessInfo.processInfo.systemUptime + 1.5)
                    }
                } else {
                    guard await until(timeout: 5, condition: { observation.sample().contains(where: \.isSelection) }),
                          let panel = windows(pid: pid).filter(\.isSelection).max(by: { $0.width * $0.height < $1.width * $1.height }) else {
                        throw DriverError.precondition("hotkey did not produce a selection overlay")
                    }
                    await pause(0.1)
                    let from = CGPoint(x: panel.x + panel.width * 0.35, y: panel.y + panel.height * 0.35)
                    let to = CGPoint(x: panel.x + panel.width * 0.55, y: panel.y + panel.height * 0.55)
                    let originalCursor = CGEvent(source: nil)?.location
                    mouse(.mouseMoved, at: from)
                    mouse(.leftMouseDown, at: from)
                    await pause(0.06)
                    for step in 1...8 {
                        let fraction = Double(step) / 8
                        mouse(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * fraction,
                                                           y: from.y + (to.y - from.y) * fraction))
                        await observation.watch(until: ProcessInfo.processInfo.systemUptime + 0.025)
                    }
                    var label: String?
                    guard await until(timeout: 1, condition: { label = sizeLabel(pid: pid); return label != nil }),
                          CGEventSource.buttonState(.combinedSessionState, button: .left) else {
                        // Collapse the region before releasing if setup failed.
                        mouse(.leftMouseDragged, at: from)
                        await pause(0.1)
                        mouse(.leftMouseUp, at: from)
                        await escape()
                        throw DriverError.precondition("could not prove an active drag using the on-screen size label and held mouse button")
                    }
                    record["dragSizeLabel"] = label!
                    await observation.watch(until: ProcessInfo.processInfo.systemUptime + Double(delay) / 1000)
                    let mouseHeldAtEscape = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    guard mouseHeldAtEscape else { throw DriverError.precondition("mouse released before Escape") }
                    record["mouseHeldAtEscape"] = mouseHeldAtEscape
                    record["escapeFromHotkeyMS"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    await escape()
                    await observation.watch(until: ProcessInfo.processInfo.systemUptime + 0.4)
                    let dismissedWhileHeld = !windows(pid: pid).contains(where: \.isSelection)
                    record["mouseHeldAfterEscapeObservation"] = CGEventSource.buttonState(.combinedSessionState, button: .left)
                    record["dismissedBeforeMouseUp"] = dismissedWhileHeld
                    record["cleanupRequired"] = !dismissedWhileHeld
                    if !dismissedWhileHeld {
                        // Avoid creating a screenshot when the tested Escape
                        // failed: collapse back to a zero-size region first.
                        mouse(.leftMouseDragged, at: from)
                        await observation.watch(until: ProcessInfo.processInfo.systemUptime + 0.1)
                        record["cleanupAction"] = "drag back to origin before mouse-up"
                        mouse(.leftMouseUp, at: from)
                    } else {
                        mouse(.leftMouseUp, at: to)
                    }
                    await observation.watch(until: ProcessInfo.processInfo.systemUptime + 1.5)
                    if windows(pid: pid).contains(where: \.isSelection) {
                        await escape()
                        await observation.watch(until: ProcessInfo.processInfo.systemUptime + 0.5)
                    }
                    if let originalCursor { mouse(.mouseMoved, at: originalCursor) }
                }
                let final = observation.sample()
                record["overlayObserved"] = observation.firstOverlayMS != nil
                record["firstOverlayMS"] = observation.firstOverlayMS
                record["editorReopened"] = observation.firstEditorMS != nil
                record["firstEditorMS"] = observation.firstEditorMS
                record["overlayDismissedAtEnd"] = !final.contains(where: \.isSelection)
                record["finalWindows"] = try snapshot(final)
                let createdImages = try imageFiles(in: saveDirectories).subtracting(existingImages)
                record["newSnipFileCount"] = createdImages.count
                record["newSnipFiles"] = createdImages.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
                records.append(record)
                try log.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10]))
                try log.synchronize()
                guard !final.contains(where: \.isSelection) else {
                    throw DriverError.precondition("could not clean up the selection overlay")
                }
                // An Escape around overlay presentation may prevent any
                // on-screen frame from being observed. Keep such startup
                // attempts explicitly unverified, never call them passes.
                if scenario == "drag", observation.firstOverlayMS == nil {
                    throw DriverError.precondition("no real capture overlay observed for drag trial")
                }
                if !createdImages.isEmpty {
                    throw DriverError.precondition("a snip file was created unexpectedly; stopping with evidence preserved")
                }
                if iteration <= 5 || iteration % 10 == 0 || iteration == count {
                    write("Progress \(iteration)/\(count): editor reopens=\(records.filter { $0["editorReopened"] as? Bool == true }.count), cleanup required=\(records.filter { $0["cleanupRequired"] as? Bool == true }.count)")
                }
            }
            let summary: [String: Any] = [
                "baseline": baseline, "scenario": scenario, "iterations": records.count,
                "confirmedOverlays": records.filter { $0["overlayObserved"] as? Bool == true }.count,
                "unverifiedCaptureAttempts": records.filter { $0["overlayObserved"] as? Bool != true }.count,
                "editorReopened": records.filter { $0["editorReopened"] as? Bool == true }.count,
                "cleanupRequired": records.filter { $0["cleanupRequired"] as? Bool == true }.count,
                "firstEscapeLeftOverlayVisible": records.filter { $0["overlayRemainedAfterFirstEscape"] as? Bool == true }.count,
                "dragCancelledBeforeMouseUp": records.filter { $0["dismissedBeforeMouseUp"] as? Bool == true }.count,
                "verifiedActiveDrags": records.filter { $0["mouseHeldAtEscape"] as? Bool == true && $0["dragSizeLabel"] != nil }.count,
                "newSnipFileCount": records.reduce(0) { $0 + ($1["newSnipFileCount"] as? Int ?? 0) },
                "delaysMS": delays, "startingState": "editor CLOSED; app running; Finder foreground",
                "input": "real system CGEvent keyboard/mouse events", "appPath": appURL.path
            ]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("summary.json"))
            write("COMPLETE: " + String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            write("BLOCKED/INVALID RUN: \(error)")
            exit(2)
        }
    }
    enum DriverError: Error { case precondition(String) }
}
