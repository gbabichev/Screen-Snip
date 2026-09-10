import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SnipHotKey: Equatable {
    static let `default` = SnipHotKey(
        keyCode: 19,
        modifiers: UInt32(cmdKey | shiftKey),
        keyDisplay: "2"
    )

    let keyCode: UInt32
    let modifiers: UInt32
    let keyDisplay: String

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyDisplay
    }

    static func load() -> SnipHotKey {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Keys.keyCode) != nil,
              defaults.object(forKey: Keys.modifiers) != nil else {
            return .default
        }

        let keyCode = UInt32(defaults.integer(forKey: Keys.keyCode))
        let modifiers = UInt32(defaults.integer(forKey: Keys.modifiers))
        let keyDisplay = keyboardLayoutKeyName(for: keyCode)
            ?? defaults.string(forKey: Keys.keyDisplay)
            ?? keyName(for: keyCode)
        return SnipHotKey(keyCode: keyCode, modifiers: modifiers, keyDisplay: keyDisplay)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: Keys.keyCode)
        defaults.set(Int(modifiers), forKey: Keys.modifiers)
        defaults.set(keyDisplay, forKey: Keys.keyDisplay)
    }

    static func from(event: NSEvent) -> SnipHotKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }

        guard modifiers != 0 else { return nil }

        let keyCode = UInt32(event.keyCode)
        let display: String
        if let specialKeyName = specialKeyName(for: keyCode) {
            display = specialKeyName
        } else {
            display = keyboardLayoutKeyName(for: keyCode) ?? keyName(for: keyCode)
        }
        return SnipHotKey(keyCode: keyCode, modifiers: modifiers, keyDisplay: display)
    }

    private enum Keys {
        static let keyCode = "snipHotKeyCode"
        static let modifiers = "snipHotKeyModifiers"
        static let keyDisplay = "snipHotKeyDisplay"
    }

    private static func keyName(for keyCode: UInt32) -> String {
        specialKeyName(for: keyCode) ?? "Key \(keyCode)"
    }

    private static func keyboardLayoutKeyName(for keyCode: UInt32) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(
                inputSource,
                kTISPropertyUnicodeKeyLayoutData
              ) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>
            .fromOpaque(layoutPointer)
            .takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var actualLength = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &actualLength,
                &characters
            )
        }

        guard status == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: actualLength).uppercased()
    }

    private static func specialKeyName(for keyCode: UInt32) -> String? {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "⌦"
        case 119: return "End"
        case 121: return "Page Down"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }
}

struct SnipHotKeyRecorder: View {
    @State private var shortcut = SnipHotKey.load()
    @State private var registrationError: String?
    @State private var isRecording = false
    @State private var errorDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HotKeyRecorderButton(
                shortcut: $shortcut,
                isRecording: $isRecording,
                onBegin: clearRegistrationError,
                onCancel: clearRegistrationError,
                onCommit: { proposedShortcut in
                    let previousShortcut = shortcut
                    proposedShortcut.save()

                    let status = GlobalHotKeyManager.shared.registerSnipHotKey()
                    if status == noErr {
                        shortcut = proposedShortcut
                        registrationError = nil
                    } else {
                        previousShortcut.save()
                        _ = GlobalHotKeyManager.shared.registerSnipHotKey()
                        showTemporaryError("Shortcut already in use")
                        NSSound.beep()
                    }
                },
                onInterrupted: {
                    showTemporaryError("Shortcut may be in use")
                    NSSound.beep()
                }
            )
            .frame(width: 112, height: 28)

            if isRecording {
                Text("Hit Esc to cancel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let registrationError {
                Text(registrationError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: clearRegistrationError)
    }

    private func showTemporaryError(_ message: String) {
        errorDismissTask?.cancel()
        registrationError = message
        errorDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            registrationError = nil
            errorDismissTask = nil
        }
    }

    private func clearRegistrationError() {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        registrationError = nil
    }
}

private struct HotKeyRecorderButton: NSViewRepresentable {
    @Binding var shortcut: SnipHotKey
    @Binding var isRecording: Bool
    let onBegin: () -> Void
    let onCancel: () -> Void
    let onCommit: (SnipHotKey) -> Void
    let onInterrupted: () -> Void

    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        button.title = shortcut.displayName
        button.normalTitle = shortcut.displayName
        button.onCommit = onCommit
        button.onBeginRecording = {
            onBegin()
            GlobalHotKeyManager.shared.suspendSnipHotKey()
        }
        button.onCancelRecording = {
            _ = GlobalHotKeyManager.shared.registerSnipHotKey()
            onCancel()
        }
        button.onInterruptedRecording = onInterrupted
        button.onRecordingStateChange = { isRecording = $0 }
        return button
    }

    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.normalTitle = shortcut.displayName
        button.onCommit = onCommit
        button.onBeginRecording = {
            onBegin()
            GlobalHotKeyManager.shared.suspendSnipHotKey()
        }
        button.onCancelRecording = {
            _ = GlobalHotKeyManager.shared.registerSnipHotKey()
            onCancel()
        }
        button.onInterruptedRecording = onInterrupted
        button.onRecordingStateChange = { isRecording = $0 }
        if !button.isRecording {
            button.title = shortcut.displayName
        }
    }
}

private final class ShortcutButton: NSButton {
    var onCommit: ((SnipHotKey) -> Void)?
    var onBeginRecording: (() -> Void)?
    var onCancelRecording: (() -> Void)?
    var onInterruptedRecording: (() -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?
    var normalTitle = ""
    var isRecording = false
    private var sawModifierInput = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(beginRecording)
    }

    @objc private func beginRecording() {
        if isRecording {
            cancelRecording()
            return
        }
        normalTitle = title
        isRecording = true
        onRecordingStateChange?(true)
        sawModifierInput = false
        title = "Type Shortcut…"
        onBeginRecording?()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        guard let shortcut = SnipHotKey.from(event: event) else {
            NSSound.beep()
            return
        }

        normalTitle = shortcut.displayName
        finishRecording()
        onCommit?(shortcut)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }

        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if !flags.isEmpty {
            sawModifierInput = true
            title = modifierDisplay(for: flags) + "…"
        } else if sawModifierInput {
            cancelInterruptedRecording()
        }
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign && isRecording {
            if sawModifierInput {
                cancelInterruptedRecording()
            } else {
                cancelRecording()
            }
        }
        return didResign
    }

    private func finishRecording() {
        isRecording = false
        onRecordingStateChange?(false)
        title = normalTitle
    }

    private func cancelRecording() {
        finishRecording()
        onCancelRecording?()
    }

    private func cancelInterruptedRecording() {
        cancelRecording()
        onInterruptedRecording?()
    }

    private func modifierDisplay(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }
}
