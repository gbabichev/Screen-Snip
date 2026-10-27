import AppKit
import ApplicationServices
import Foundation

// External end-to-end driver. It never calls Screen Snip's capture/cancel code.
// Run --preflight first; event posting requires existing macOS authorization.
@MainActor
@main
struct EditedCaptureChecks {
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
    static func require(_ success: Bool, _ message: String) throws {
        guard success else { throw DriverError.precondition(message) }
    }
    static func editorIDs(_ pid: pid_t) -> Set<Int> { Set(windows(pid: pid).filter(\.isEditor).map(\.id)) }
    static func focusedWindow(_ pid: pid_t) throws -> AXUIElement {
        guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { throw DriverError.precondition("no focused window") }
        return value as! AXUIElement
    }
    static func edited(_ window: AXUIElement) -> Bool {
        if let close = attribute(window, kAXCloseButtonAttribute), CFGetTypeID(close) == AXUIElementGetTypeID() {
            return (attribute(close as! AXUIElement, kAXEditedAttribute) as? NSNumber)?.boolValue == true
        }
        return (attribute(window, kAXEditedAttribute) as? NSNumber)?.boolValue == true
    }
    static func selected(_ window: AXUIElement) -> Bool {
        elements(window).contains { attribute($0,kAXRoleAttribute) as? String == kAXButtonRole && label($0).contains("Crop") }
    }
    static func alert(_ pid: pid_t) -> AXUIElement? {
        appWindows(pid).first { elements($0).contains { label($0).contains("Your edits will be lost") } }
    }
    static func alertText(_ window: AXUIElement) -> String {
        elements(window).map(label).first { $0.contains("Save changes to") } ?? ""
    }
    static func press(_ window: AXUIElement, button text: String) throws {
        let text = text == "Don't Save" ? "Discard" : text
        guard let button = elements(window).first(where: {
            attribute($0,kAXRoleAttribute) as? String == kAXButtonRole &&
            label($0).replacingOccurrences(of: "’",with: "'").contains(text)
        }), AXUIElementPerformAction(button,kAXPressAction as CFString) == .success else {
            throw DriverError.precondition("missing alert button \(text)")
        }
    }
    static func activate(_ app: NSRunningApplication) async throws {
        app.activate(options: [])
        guard await until(timeout: 2, condition: { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }) else { throw DriverError.precondition("app did not become active") }
        await pause(0.1)
    }
    static func cancelCapture(_ pid: pid_t, finder: NSRunningApplication) async throws {
        finder.activate(options: [])
        guard await until(timeout: 2, condition: { NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier }) else { throw DriverError.precondition("Finder focus") }
        await captureHotkey()
        guard await until(timeout: 5, condition: { windows(pid: pid).contains(where: \.isSelection) }) else { throw DriverError.precondition("capture overlay missing") }
        await escape()
        guard await until(timeout: 3, condition: { !windows(pid: pid).contains(where: \.isSelection) }) else { throw DriverError.precondition("Escape failed") }
        await pause(0.3)
    }
    static func main() async {
        let args=CommandLine.arguments
        guard args.count==4, CGPreflightPostEventAccess(), AXIsProcessTrusted() else {
            write("Usage: EditedCaptureChecks APP_PATH FIXTURE_PNG OUTPUT_DIRECTORY");exit(2)
        }
        defer { if let point=heldMousePosition { mouse(.leftMouseUp,at:point) } }
        let appURL=URL(fileURLWithPath:args[1]), fixture=URL(fileURLWithPath:args[2])
        let output=URL(fileURLWithPath:args[3],isDirectory:true)
        var results:[String:Bool]=[:]
        do {
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let config=NSWorkspace.OpenConfiguration();config.activates=true
            let app=try await NSWorkspace.shared.openApplication(at:appURL,configuration:config)
            let pid=app.processIdentifier
            guard let finder=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first else { throw DriverError.precondition("Finder missing") }
            let priorHide=try await setHide(true,app:app)
            _=try await NSWorkspace.shared.open([fixture],withApplicationAt:appURL,configuration:config)
            await pause(0.3)
            try await activate(app)
            var original=try focusedWindow(pid)
            try require(selected(original),"fixture not selected")
            let originalIDs=editorIDs(pid)

            // Minimized editors remain minimized and retain their view.
            try require(AXUIElementSetAttributeValue(original,kAXMinimizedAttribute as CFString,kCFBooleanTrue) == .success,"minimize")
            await pause(0.4)
            try await cancelCapture(pid,finder:finder)
            try require((attribute(original,kAXMinimizedAttribute) as? NSNumber)?.boolValue==true && editorIDs(pid).isEmpty,"minimized editor was restored unexpectedly")
            try require(AXUIElementSetAttributeValue(original,kAXMinimizedAttribute as CFString,kCFBooleanFalse) == .success,"deminimize")
            await pause(0.4)
            try require(editorIDs(pid)==originalIDs && selected(original),"minimized editor state lost")
            results["minimized_editor_preserved"]=true;write("PASS: minimized editor stays minimized and keeps its image")

            // A hidden application remains hidden after cancellation.
            try await activate(app);await command(4) // Command-H.
            guard await until(timeout:2,condition:{app.isHidden}) else { throw DriverError.precondition("app did not hide") }
            try await cancelCapture(pid,finder:finder)
            try require(app.isHidden && editorIDs(pid).isEmpty,"hidden app was unhidden on cancellation")
            app.unhide();try await activate(app);await pause(0.2)
            try require(editorIDs(pid)==originalIDs && selected(original),"hidden editor state lost")
            results["hidden_app_preserved"]=true;write("PASS: hidden app stays hidden and keeps its image")

            // Settings survive along with the editor.
            await command(43);await pause(0.2)
            guard appWindows(pid).contains(where:{(attribute($0,"AXIdentifier") as? String)=="com_apple_SwiftUI_Settings_window"}) else { throw DriverError.precondition("settings window missing") }
            let beforeSettings=editorIDs(pid)
            try require(beforeSettings.count==2,"expected editor and Settings")
            try await cancelCapture(pid,finder:finder)
            try require(editorIDs(pid)==beforeSettings,"Settings or editor window identity changed")
            guard let restoredSettings=appWindows(pid).first(where:{(attribute($0,"AXIdentifier") as? String)=="com_apple_SwiftUI_Settings_window"}),
                  let close=attribute(restoredSettings,kAXCloseButtonAttribute) else { throw DriverError.precondition("restored Settings close button missing") }
            try require(AXUIElementPerformAction(close as! AXUIElement,kAXPressAction as CFString) == .success,"close Settings")
            try await activate(app)
            original=try focusedWindow(pid)
            try require(selected(original),"editor image missing after closing Settings")
            results["settings_window_preserved"]=true;write("PASS: Settings and selected editor keep their original windows")

            // Rotation is an unsaved edit; cancel must preserve it.
            try await activate(app);await command(15)
            guard await until(timeout:2,condition:{edited(original)}) else { throw DriverError.precondition("rotation did not mark editor edited") }
            try await cancelCapture(pid,finder:finder)
            try await activate(app)
            original=try focusedWindow(pid)
            try require(editorIDs(pid)==originalIDs && edited(original) && selected(original),"unsaved edit lost on cancel")
            results["unsaved_cancel_preserved"]=true;write("PASS: cancellation preserves the original edited window")

            // Complete a real capture with the old editor still dirty.
            finder.activate(options:[]);await pause(0.1);await captureHotkey()
            guard await until(timeout:5,condition:{windows(pid:pid).contains(where:\.isSelection)}),
                  let panel=windows(pid:pid).filter(\.isSelection).max(by:{$0.width*$0.height<$1.width*$1.height}) else { throw DriverError.precondition("success capture overlay missing") }
            let from=CGPoint(x:panel.x+panel.width*0.35,y:panel.y+panel.height*0.35)
            let to=CGPoint(x:panel.x+panel.width*0.5,y:panel.y+panel.height*0.5)
            let oldCursor=CGEvent(source:nil)?.location
            mouse(.mouseMoved,at:from);mouse(.leftMouseDown,at:from);await pause(0.05)
            for n in 1...8 { let f=Double(n)/8;mouse(.leftMouseDragged,at:CGPoint(x:from.x+(to.x-from.x)*f,y:from.y+(to.y-from.y)*f));await pause(0.03) }
            guard await until(timeout:1,condition:{sizeLabel(pid:pid) != nil}) else { throw DriverError.precondition("actual capture drag not verified") }
            mouse(.leftMouseUp,at:to)
            guard await until(timeout:5,condition:{editorIDs(pid).count==2 && !windows(pid:pid).contains(where:\.isSelection)}) else { throw DriverError.precondition("capture did not open a second editor") }
            await pause(0.3);try await activate(app)
            let captured=try focusedWindow(pid)
            try require(!CFEqual(original,captured) && selected(captured) && !edited(captured),"new capture did not load in a separate clean editor")
            guard let oldEditedWindow=appWindows(pid).first(where:{edited($0)}) else { throw DriverError.precondition("old dirty editor missing") }
            original=oldEditedWindow
            try require(originalIDs.isSubset(of:editorIDs(pid)),"old editor window ID changed")
            _=AXUIElementPerformAction(original,kAXRaiseAction as CFString)
            await pause(0.2)
            try require(edited(original) && selected(original),"old unsaved editor was overwritten")
            _=AXUIElementPerformAction(captured,kAXRaiseAction as CFString)
            await pause(0.2)
            results["successful_capture_preserves_unsaved_editor"]=true;write("PASS: completed capture opens a separate editor and preserves old unsaved work")
            if let oldCursor { mouse(.mouseMoved,at:oldCursor) }

            // Commands must affect only the active editor.
            await command(15)
            guard await until(timeout:2,condition:{edited(captured)}) else { throw DriverError.precondition("new editor did not rotate") }
            await command(6)
            guard await until(timeout:2,condition:{!edited(captured)}) else { throw DriverError.precondition("undo did not clean the active editor") }
            try require(edited(original),"undo also changed the old editor")
            results["undo_scoped_to_active_editor"]=true;write("PASS: undo targets only the active editor")

            // Both dirty editors must participate in termination confirmation.
            await command(15);await pause(0.2);await command(12)
            guard await until(timeout:2,condition:{alert(pid) != nil}),let first=alert(pid) else { throw DriverError.precondition("quit confirmation missing") }
            let firstMessage=alertText(first)
            try press(first,button:"Don't Save")
            guard await until(timeout:2,condition:{guard let a=alert(pid) else{return false};return alertText(a) != firstMessage}),let second=alert(pid) else { throw DriverError.precondition("quit did not ask about the other edited window") }
            try press(second,button:"Cancel")
            await pause(0.2)
            try require(!app.isTerminated && editorIDs(pid).count==2,"Cancel quit did not keep both editors")
            results["quit_confirms_each_dirty_editor"]=true;write("PASS: quit asks about each dirty editor; Cancel keeps app and windows")

            // Only these test-created edits are discarded during cleanup.
            for window in [captured,original] {
                if let close=attribute(window,kAXCloseButtonAttribute) {
                    _=AXUIElementPerformAction(close as! AXUIElement,kAXPressAction as CFString)
                    await pause(0.2)
                    if let a=alert(pid) { try press(a,button:"Don't Save");await pause(0.2) }
                }
            }
            try await setHide(priorHide,app:app)
            if !editorIDs(pid).isEmpty { try closeEditor(pid:pid) }
            let report:[String:Any]=["results":results,"allPassed":results.values.allSatisfy{$0},"checks":results.count,"appPath":appURL.path]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("summary.json"))
            write("COMPLETE: \(results.count) live state/unsaved-work checks passed")
        } catch {
            let data:[String:Any]=["passedChecks":results,"error":String(describing:error)]
            try? JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("failure.json"))
            write("FAILED: \(error)");exit(2)
        }
    }
    enum DriverError: Error { case precondition(String) }
}
