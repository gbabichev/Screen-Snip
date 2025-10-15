import SwiftUI
import AppKit

struct InlineTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var textColor: NSColor
    var backgroundColor: NSColor?
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.drawsBackground = backgroundColor != nil
        textView.backgroundColor = backgroundColor ?? .clear
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = textColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator

        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.installEventMonitor()
        context.coordinator.parent = self

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        context.coordinator.parent = self
        if isFocused {
            context.coordinator.installEventMonitor()
        } else {
            context.coordinator.removeEventMonitor()
        }

        if textView.string != text {
            textView.string = text
        }

        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
        }

        if textView.textColor != textColor {
            textView.textColor = textColor
        }

        let shouldDrawBackground = backgroundColor != nil
        if textView.drawsBackground != shouldDrawBackground {
            textView.drawsBackground = shouldDrawBackground
        }
        if let bg = backgroundColor, textView.backgroundColor != bg {
            textView.backgroundColor = bg
        }
        if backgroundColor == nil {
            textView.backgroundColor = .clear
        }

        if isFocused {
            if textView.window?.firstResponder != textView {
                textView.window?.makeFirstResponder(textView)
                textView.selectedRange = NSRange(location: textView.string.count, length: 0)
            }
        } else if textView.window?.firstResponder == textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextEditor
        weak var textView: NSTextView?
        private var keyMonitor: Any?

        init(_ parent: InlineTextEditor) {
            self.parent = parent
        }

        func installEventMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, let tv = self.textView else { return event }
                if event.modifierFlags.contains(.command),
                   let characters = event.charactersIgnoringModifiers?.lowercased(),
                   characters == "a" {
                    tv.selectAll(nil)
                    return nil
                }
                return event
            }
        }

        func removeEventMonitor() {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView, notification.object as? NSTextView === tv else { return }
            parent.text = tv.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard notification.object as? NSTextView === textView else { return }
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard notification.object as? NSTextView === textView else { return }
            if parent.isFocused {
                parent.isFocused = false
            }
            removeEventMonitor()
        }
    }
}
