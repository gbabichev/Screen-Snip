import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var menuState: MenuState
    let appDelegate: AppDelegate
    
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button {
                appDelegate.showAboutWindow()
            } label: {
                Label("About Screen Snip", systemImage: "info.circle")
            }
            
            Divider()
            
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Screen Snip", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        
        CommandGroup(after: .newItem) {
            Button {
                NotificationCenter.default.post(
                    name: .openImageFile,
                    object: nil
                )
            } label: {
                Label("Open", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
                        
            Button {
                NotificationCenter.default.post(name: .saveImage, object: nil)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)
            
            Button {
                NotificationCenter.default.post(name: .saveAsImage, object: nil)
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down.on.square")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!menuState.hasSelectedImage)
            
            Divider()
            
            Button {
                if let window = NSApplication.shared.keyWindow {
                    window.performClose(nil)
                }
            } label: {
                Label("Close Window", systemImage: "xmark.circle")
            }
            .keyboardShortcut("w", modifiers: .command)
            
        }
        
        CommandGroup(replacing: .undoRedo) {
            Button {
                NotificationCenter.default.post(name: .performUndo, object: nil)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!menuState.canUndo)
            
            Button {
                NotificationCenter.default.post(name: .performRedo, object: nil)
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!menuState.canRedo)
        }
        
        CommandGroup(replacing: .pasteboard) {
            Button {
                NotificationCenter.default.post(name: .copyToClipboard, object: nil)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)
        }
        
        CommandMenu("Tools") {
            Button {
                NotificationCenter.default.post(
                    name: .selectTool,
                    object: nil,
                    userInfo: ["tool": ToolKind.pointer.rawValue]
                )
            } label: {
                Label("Pointer", systemImage: "cursorarrow")
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)

            Button {
                NotificationCenter.default.post(
                    name: .selectTool,
                    object: nil,
                    userInfo: ["tool": ToolKind.pen.rawValue]
                )
            } label: {
                Label("Pen", systemImage: "pencil.line")
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)

            Button {
                NotificationCenter.default.post(
                    name: .selectTool,
                    object: nil,
                    userInfo: ["tool": ToolKind.arrow.rawValue]
                )
            } label: {
                Label("Arrow", systemImage: "arrow.right")
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)

            Button {
                NotificationCenter.default.post(
                    name: .selectTool,
                    object: nil,
                    userInfo: ["tool": ToolKind.highlighter.rawValue]
                )
            } label: {
                Label("Highlighter", systemImage: "highlighter")
            }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)

            Button {
                NotificationCenter.default.post(
                    name: .selectTool,
                    object: nil,
                    userInfo: ["tool": ToolKind.rect.rawValue]
                )
            } label: {
                Label("Rectangle", systemImage: "square.dashed")
            }
            .keyboardShortcut("5", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)
            
            Button {
                NotificationCenter.default.post(
                    name: .selectTool,
                    object: nil,
                    userInfo: ["tool": ToolKind.oval.rawValue]
                )
            } label: {
                Label("Oval", systemImage: "circle.dashed")
            }
            .keyboardShortcut("6", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)

            Button {
                NotificationCenter.default.post(
                    name: .selectTool,
                    object: nil,
                    userInfo: ["tool": ToolKind.increment.rawValue]
                )
            } label: {
                Label("Badge", systemImage: "1.circle")
            }
            .keyboardShortcut("7", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)

            Button {
                NotificationCenter.default.post(
                    name: .selectTool,
                    object: nil,
                    userInfo: ["tool": ToolKind.text.rawValue]
                )
            } label: {
                Label("Text", systemImage: "textformat")
            }
            .keyboardShortcut("8", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)

            Button {
                NotificationCenter.default.post(
                    name: .selectTool,
                    object: nil,
                    userInfo: ["tool": ToolKind.crop.rawValue]
                )
            } label: {
                Label("Crop", systemImage: "crop")
            }
            .keyboardShortcut("9", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)
        }
        
        CommandGroup(after: .sidebar) {
            Button {
                NotificationCenter.default.post(name: .zoomIn, object: nil)
            } label: { Text("Zoom In") }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)

            Button {
                NotificationCenter.default.post(name: .zoomOut, object: nil)
            } label: { Text("Zoom Out") }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)

            Button {
                NotificationCenter.default.post(name: .resetZoom, object: nil)
            } label: { Text("Actual Size") }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(!menuState.hasSelectedImage)
            
            Divider()
        }
        
        CommandGroup(replacing: .help) {
            Button {
                // Open help URL - replace with your actual help URL
                if let url = URL(string: "https://gbabichev.github.io/Screen-Snip/Documentation/Support.html") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            
            Button {
                // Show privacy policy alert
                let alert = NSAlert()
                alert.messageText = "Privacy Policy"
                alert.informativeText = "No data leaves your device ever - I don't touch it / know about it / care about it. It's yours."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } label: {
                Label("Privacy Policy", systemImage: "hand.raised.circle")
            }
        }
    }
}
