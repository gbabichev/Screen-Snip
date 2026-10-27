import AppKit
import ApplicationServices
import Foundation

// External end-to-end driver. It never calls Screen Snip's capture/cancel code.
// Run --preflight first; event posting requires existing macOS authorization.
@MainActor
@main
struct MatrixEscapeStress {
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
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    static func appWindows(_ pid: pid_t) -> [AXUIElement] {
        attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }
    static func elements(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        func visit(_ node: AXUIElement, depth: Int) {
            guard depth < 14, result.count < 500 else { return }
            result.append(node)
            for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return result
    }
    static func label(_ node: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .compactMap { attribute(node, $0) as? String }.joined(separator: " ")
    }
    static func selectedImageState(pid: pid_t) -> [String: Any] {
        let visible = windows(pid: pid).contains(where: \.isEditor)
        guard visible else { return ["editorVisible": false, "imageControlsPresent": false, "blankPromptVisible": false] }
        let nodes = appWindows(pid).flatMap(elements)
        let labels = nodes.map(label)
        return [
            "editorVisible": true,
            "imageControlsPresent": nodes.contains {
                attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && label($0).contains("Crop")
            },
            "blankPromptVisible": labels.contains { $0.contains("or click 'Capture' to begin") }
        ]
    }
    static func command(_ code: CGKeyCode) async {
        key(55, down: true, flags: .maskCommand)
        key(code, down: true, flags: .maskCommand)
        await pause(0.02)
        key(code, down: false, flags: .maskCommand)
        key(55, down: false)
    }
    @discardableResult static func setHide(_ desired: Bool, app: NSRunningApplication) async throws -> Bool {
        app.activate(options: [])
        await pause(0.1)
        await command(43) // Command-comma: open the app's real Settings window.
        await pause(0.2)
        let pid = app.processIdentifier
        for _ in 0..<3 {
            if appWindows(pid).flatMap(elements).contains(where: { label($0).contains("Hide Screen Snip During Capture") }) { break }
            if let captureTab = appWindows(pid).flatMap(elements).first(where: {
                attribute($0, kAXRoleAttribute) as? String == kAXButtonRole && label($0) == "Capture"
            }) {
                guard AXUIElementPerformAction(captureTab, kAXPressAction as CFString) == .success else {
                    throw DriverError.precondition("could not select Capture settings tab")
                }
            }
            await pause(0.15)
        }
        guard let settings = appWindows(pid).first(where: {
            elements($0).contains { label($0).contains("Hide Screen Snip During Capture") }
        }) else { throw DriverError.precondition("could not locate Capture settings") }
        let nodes = elements(settings)
        guard let index = nodes.firstIndex(where: { label($0).contains("Hide Screen Snip During Capture") }),
              let toggle = nodes.dropFirst(index + 1).prefix(5).first(where: {
                  let role = attribute($0, kAXRoleAttribute) as? String ?? ""
                  return [kAXCheckBoxRole, "AXSwitch", kAXButtonRole].contains(role) && attribute($0, kAXValueAttribute) is NSNumber
              }), let old = attribute(toggle, kAXValueAttribute) as? NSNumber else {
            write("Settings nodes: " + nodes.map { "\(attribute($0, kAXRoleAttribute) ?? "?" as CFString):\(label($0)) value=\(String(describing: attribute($0, kAXValueAttribute)))" }.joined(separator: " | "))
            throw DriverError.precondition("could not locate hide-during-capture toggle")
        }
        if old.boolValue != desired {
            guard AXUIElementPerformAction(toggle, kAXPressAction as CFString) == .success else {
                throw DriverError.precondition("could not toggle hide-during-capture")
            }
            await pause(0.1)
        }
        guard (attribute(toggle, kAXValueAttribute) as? NSNumber)?.boolValue == desired else {
            throw DriverError.precondition("hide toggle did not reach requested state")
        }
        guard let close = attribute(settings, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString) == .success else {
            throw DriverError.precondition("could not close Settings")
        }
        await pause(0.15)
        return old.boolValue
    }
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 5, let count = Int(args[3]), count > 0,
              CGPreflightPostEventAccess(), AXIsProcessTrusted() else {
            write("Usage: MatrixEscapeStress APP_PATH FIXTURE_PNG REPETITIONS_PER_CASE OUTPUT_DIRECTORY [BASELINE_SHA]")
            exit(2)
        }
        defer { if let point = heldMousePosition { mouse(.leftMouseUp, at: point) } }
        let appURL = URL(fileURLWithPath: args[1])
        let fixture = URL(fileURLWithPath: args[2]).standardizedFileURL
        let output = URL(fileURLWithPath: args[4], isDirectory: true)
        let baseline = args.count > 5 ? args[5] : "unspecified"
        let focused = args.contains("--open-hide-only")
        let hideStates = focused ? [true] : [false, true]
        let windowStates = focused ? [true] : [false, true]
        let total = count * hideStates.count * windowStates.count * 3
        do {
            guard FileManager.default.fileExists(atPath: fixture.path) else { throw DriverError.precondition("fixture missing") }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let logURL = output.appendingPathComponent("trials.jsonl")
            guard !FileManager.default.fileExists(atPath: logURL.path) else { throw DriverError.precondition("choose a fresh output directory") }
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            guard app.bundleURL?.resolvingSymlinksInPath() == appURL.resolvingSymlinksInPath() else { throw DriverError.precondition("different app bundle launched") }
            let pid = app.processIdentifier
            await pause(1)
            guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { throw DriverError.precondition("Finder not running") }
            var saveDirectories = [FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Screen Snip", isDirectory: true)]
            if let id = app.bundleIdentifier, let custom = UserDefaults(suiteName: id)?.string(forKey: "saveDirectoryPath"), !custom.isEmpty { saveDirectories.append(URL(fileURLWithPath: custom)) }
            var records: [[String: Any]] = []
            var originalHide: Bool?
            write("MATRIX baseline=\(baseline); pid=\(pid); \(count) repetitions per case; total=\(total)")
            for hideEnabled in hideStates {
                for initiallyOpen in windowStates {
                    let priorHide = try await setHide(hideEnabled, app: app)
                    if originalHide == nil { originalHide = priorHide }
                    for scenario in ["normal", "startup", "drag"] {
                        let delays = scenario == "startup" ? [40,125,300,475,550] : [0,25,75,150,300]
                        for iteration in 1...count {
                            _ = try await NSWorkspace.shared.open([fixture], withApplicationAt: appURL, configuration: config)
                            await pause(0.25)
                            guard await until(timeout: 3, condition: { selectedImageState(pid: pid)["imageControlsPresent"] as? Bool == true }) else {
                                throw DriverError.precondition("fixture did not produce selected-image controls")
                            }
                            if !initiallyOpen { try closeEditor(pid: pid) }
                            guard await until(timeout: 3, condition: { windows(pid: pid).contains(where: \.isEditor) == initiallyOpen }) else { throw DriverError.precondition("wrong initial editor visibility") }
                            finder.activate(options: [])
                            guard await until(timeout: 2, condition: { NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier }) else { throw DriverError.precondition("Finder did not become foreground") }
                            await pause(0.1)
                            let initial = windows(pid: pid)
                            let initialSelection = selectedImageState(pid: pid)
                            guard initial.contains(where: \.isEditor) == initiallyOpen, !initial.contains(where: \.isSelection),
                                  !initiallyOpen || initialSelection["imageControlsPresent"] as? Bool == true else { throw DriverError.precondition("invalid initial state") }
                            let existingImages = try imageFiles(in: saveDirectories)
                            let start = ProcessInfo.processInfo.systemUptime
                            let observation = Observation(pid: pid, start: start)
                            let delay = delays[(iteration - 1) % delays.count]
                            var record: [String: Any] = [
                                "iteration": iteration, "scenario": scenario, "initiallyOpen": initiallyOpen,
                                "hideEnabled": hideEnabled, "initialWindows": try snapshot(initial),
                                "initialSelection": initialSelection, "requestedDelayMS": delay,
                                "startedAt": ISO8601DateFormatter().string(from: Date())
                            ]
                await captureHotkey()
                if scenario == "normal" {
                    guard await until(timeout: 5, condition: { observation.sample().contains(where: \.isSelection) }) else {
                        throw DriverError.precondition("normal hotkey did not produce overlay")
                    }
                    record["editorVisibleDuringOverlay"] = windows(pid: pid).contains(where: \.isEditor)
                    await observation.watch(until: ProcessInfo.processInfo.systemUptime + Double(delay) / 1000)
                    await escape()
                    await observation.watch(until: ProcessInfo.processInfo.systemUptime + 1.5)
                } else if scenario == "startup" {
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
                            let finalSelection = selectedImageState(pid: pid)
                            let editorVisible = final.contains(where: \.isEditor)
                            record["overlayObserved"] = observation.firstOverlayMS != nil
                            record["firstOverlayMS"] = observation.firstOverlayMS
                            record["overlayDismissedAtEnd"] = !final.contains(where: \.isSelection)
                            record["editorVisibleAtEnd"] = editorVisible
                            record["windowStatePreserved"] = editorVisible == initiallyOpen
                            record["unexpectedEditorOpened"] = !initiallyOpen && observation.firstEditorMS != nil
                            record["finalWindows"] = try snapshot(final)
                            record["finalSelection"] = finalSelection
                            record["frontmostApplicationAtEnd"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                            record["foregroundRestored"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier
                            if initiallyOpen {
                                record["selectionPreserved"] = finalSelection["imageControlsPresent"] as? Bool == true && finalSelection["blankPromptVisible"] as? Bool != true
                                record["returnedBlank"] = editorVisible && finalSelection["blankPromptVisible"] as? Bool == true
                            }
                            let created = try imageFiles(in: saveDirectories).subtracting(existingImages)
                            record["newSnipFileCount"] = created.count
                            records.append(record)
                            try log.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10]))
                            try log.synchronize()
                            write("\(records.count)/\(total): \(scenario) open=\(initiallyOpen) hide=\(hideEnabled) repeat=\(iteration); windowOK=\(editorVisible == initiallyOpen); selected=\(finalSelection["imageControlsPresent"] ?? false); blank=\(finalSelection["blankPromptVisible"] ?? false)")
                            guard !final.contains(where: \.isSelection), created.isEmpty else { throw DriverError.precondition("overlay remained or snip file created") }
                        }
                    }
                }
            }
            if let originalHide { try await setHide(originalHide, app: app) }
            if windows(pid: pid).contains(where: \.isEditor) { try closeEditor(pid: pid) }
            let summary: [String: Any] = [
                "baseline": baseline, "trials": records.count, "repetitionsPerCase": count,
                "focusedOpenHideOnly": focused,
                "fixture": fixture.path, "confirmedOverlays": records.filter { $0["overlayObserved"] as? Bool == true }.count,
                "windowStateFailures": records.filter { $0["windowStatePreserved"] as? Bool != true }.count,
                "unexpectedEditorOpens": records.filter { $0["unexpectedEditorOpened"] as? Bool == true }.count,
                "openEditorTrials": records.filter { $0["initiallyOpen"] as? Bool == true }.count,
                "selectionPreserved": records.filter { $0["selectionPreserved"] as? Bool == true }.count,
                "returnedBlank": records.filter { $0["returnedBlank"] as? Bool == true }.count,
                "newSnipFileCount": records.reduce(0) { $0 + ($1["newSnipFileCount"] as? Int ?? 0) },
                "selectionCheck": "Image-only Crop toolbar button versus blank Capture prompt; fixture reopened before every trial"
            ]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("summary.json"))
            write("COMPLETE: " + String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
        } catch { write("BLOCKED/INVALID MATRIX: \(error)"); exit(2) }
    }
    enum DriverError: Error { case precondition(String) }
}
