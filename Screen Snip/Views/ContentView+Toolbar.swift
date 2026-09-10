import SwiftUI

extension ContentView {
    @ToolbarContentBuilder
    func toolbarContent() -> some ToolbarContent {
                    // Items visible only when we have a capture
                    if selectedSnipURL != nil {
                        
                        if imageDisplayMode != "fit"{
                            ToolbarItemGroup(placement: .navigation){
                                HStack {
                                    
                                    Slider(value: $zoomLevel, in: ZOOM_MIN...ZOOM_MAX) {
                                        Text("Zoom")
                                    }
                                    .frame(width: 80)
                                    
                                    Button(action: { zoomLevel = 1.0 }) {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .padding(.trailing)
                                    .buttonStyle(.plain)
                                    .help("Reset zoom")
                                }
                            }
                        }
                        
                        
                        //MARK: - TOOLS: Copy to Cliboard, Undo, Redo, Flatten, Save, Save As.
                        
                        ToolbarItemGroup(placement: .navigation){
                            
                            Menu {
                                
                                // Undo
                                Button(action: performUndo) {
                                    Label("Undo", systemImage: "arrow.uturn.backward")
                                }
                                .disabled(undoStack.isEmpty || selectedSnipURL == nil)
                                
                                // Redo
                                Button(action: performRedo) {
                                    Label("Redo", systemImage: "arrow.uturn.forward")
                                }
                                .disabled(redoStack.isEmpty || selectedSnipURL == nil)
                                
                                // Flatten and Save (in place)
                                Button(action: { flattenAndSaveInPlace() }) {
                                    Label("Save", systemImage: "square.and.arrow.down")
                                }
                                
                                // Flatten and Save As
                                Button(action: flattenAndSaveAs) {
                                    Label("Save As", systemImage: "square.and.arrow.down.on.square")
                                }
                                
                            } label: {
                                Label("Copy to Clipboard", systemImage: "doc.on.doc")
                            } primaryAction: {
                                // Flatten & Copy to Clipboard
                                flattenRefreshAndCopy()
                                selectedTool = .pointer
                                selectedObjectID = nil
                                activeHandle = .none
                                cropDraftRect = nil
                                cropRect = nil
                                cropHandle = .none
                                focusedTextID = nil
                            }
                        }
                        
                        // MARK: - TOOLS: Pointer, Pen, Arrow, Highlighter.
                        
                        ToolbarItem(id: "pointer", placement: .navigation) {
                            Button(action: { selectedTool = .pointer
                                selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                focusedTextID = nil
                                
                            }) {
                                Label("Pointer", systemImage: "cursorarrow")
                                    .foregroundStyle(selectedTool == .pointer ? Color.white : Color.primary)
                                
                            }
                            .glassEffect(selectedTool == .pointer ? .regular.tint(.blue) : .regular)
                        }
                        
                        
                        ToolbarItem(id: "pens", placement: .principal) {
                            // Pen, Arrow, Highlighter.
                            
                            Menu {
                                // Always show all three tools first
                                Button(action: {
                                    selectedTool = .line
                                    lineHasArrow = false
                                    selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                    focusedTextID = nil
                                }) {
                                    HStack {
                                        Image(systemName: "pencil.line")
                                        Text("Pen")
                                    }
                                }
                                
                                Button(action: {
                                    selectedTool = .line
                                    lineHasArrow = true
                                    selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                    focusedTextID = nil
                                }) {
                                    HStack {
                                        Image(systemName: "arrow.right")
                                        Text("Arrow")
                                    }
                                }
                                
                                Button(action: {
                                    selectedTool = .highlighter
                                    selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                    focusedTextID = nil
                                }) {
                                    HStack {
                                        Image(systemName: "highlighter")
                                        Text("Highlighter")
                                    }
                                }
                                
                                Divider()
                                
                                if selectedTool == .highlighter {
                                    highlightColorButtons(current: highlighterColorBinding)
                                }
                                else {
                                    colorButtons(current: lineColorBinding)
                                }
                                
                                Divider()
                                
                                Menu("Line Width") {
                                    ForEach([1,2,3,4,6,8,12,16], id: \.self) { w in
                                        Button(action: { strokeWidth = CGFloat(w) }) {
                                            if Int(strokeWidth) == w { Image(systemName: "checkmark") }
                                            Text("\(w) pt")
                                        }
                                    }
                                }
                                
                            } label: {
                                if selectedTool == .highlighter {
                                    Label("Shapes", systemImage: "highlighter")
                                        .frame(width: 200)
                                        .fixedSize()
                                }
                                else if selectedTool == .line && lineHasArrow == true {
                                    Label("Shapes", systemImage: "arrow.right")
                                        .frame(width: 200)
                                        .fixedSize()
                                }
                                else {
                                    Label("Shapes", systemImage: "pencil.line")
                                        .frame(width: 200)
                                        .fixedSize()
                                }
                            } primaryAction: {
                                if selectedTool == .line && lineHasArrow == true {
                                    selectedTool = .line
                                    lineHasArrow = true
                                    selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                    focusedTextID = nil
                                }
                                else if selectedTool == .highlighter {
                                    selectedTool = .highlighter
                                    selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                    focusedTextID = nil
                                }
                                else {
                                    selectedTool = .line
                                    lineHasArrow = false
                                    selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                    focusedTextID = nil
                                }
                            }
                            .id("\(selectedTool)-\(lineHasArrow)-\(lineColor)-\(highlighterColor)")
                            .glassEffect(
                                (selectedTool == .line || selectedTool == .highlighter)
                                ? .regular.tint(
                                    Color(nsColor: selectedTool == .line
                                          ? lineColor
                                          : highlighterColor
                                         ).opacity(0.7)
                                )
                                : .regular
                            )
                            
                        }
                        
                        
                        // MARK: - TOOLS - SHAPE & Increment
                        
                        ToolbarItemGroup(placement: .principal) {
                            // Shape rectable and oval
                            Menu {
                                Button {
                                    selectedTool = .rect
                                    selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                    focusedTextID = nil
                                } label: {
                                    Label("Rectangle", systemImage: "square.dashed")
                                }
        
                                Button {
                                    selectedTool = .oval
                                    selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                    focusedTextID = nil
                                } label: {
                                    Label("Oval", systemImage: "circle.dashed")
                                }
        
                                Button {
                                    selectedTool = .blur
                                    selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                    focusedTextID = nil
                                } label: {
                                    Label("Blur", systemImage: "circle.dotted")
                                }
        
        
                                Divider()
        
                                if selectedTool == .oval {
                                    colorButtons(current: ovalColorBinding)
                                }
                                else if selectedTool == .rect {
                                    colorButtons(current: rectColorBinding)
                                }
        
                                if selectedTool == .blur {
                                    Menu("Blur Amount") {
                                        ForEach([3, 5, 8, 10, 12, 15, 20, 25], id: \.self) { amount in
                                            Button(action: { blurAmount = Double(amount) }) {
                                                if Int(blurAmount) == amount { Image(systemName: "checkmark") }
                                                Text("\(amount)")
                                            }
                                        }
                                    }
                                } else {
                                    Divider()
        
                                    Menu("Line Width") {
                                        ForEach([1,2,3,4,6,8,12,16], id: \.self) { w in
                                            Button(action: { strokeWidth = CGFloat(w) }) {
                                                if Int(strokeWidth) == w { Image(systemName: "checkmark") }
                                                Text("\(w) pt")
                                            }
                                        }
                                    }
                                }
        
                            } label: {
                                if selectedTool == .oval {
                                    Label("Shapes", systemImage: "circle.dashed")
                                }
                                else if selectedTool == .blur {
                                    Label("Shapes", systemImage: "circle.dotted")
                                }
                                else {
                                    Label("Shapes", systemImage: "square.dashed")
                                }
                                
                            } primaryAction: {
                                selectedTool = .rect
                                selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                                focusedTextID = nil
                            }
                            .id("\(selectedTool)-\(rectColor.description)-\(ovalColor.description)")
                            .glassEffect(
                                selectedTool == .oval
                                ? .regular.tint(Color(nsColor: ovalColor).opacity(0.7))
                                : selectedTool == .rect
                                ? .regular.tint(Color(nsColor: rectColor).opacity(0.7))
                                : selectedTool == .blur
                                ? .regular.tint(Color.gray.opacity(0.5))
                                : .regular
                            )
                            .help("Click to draw a shape")
                            
                            // Increment (badge)
                            Menu {
                                colorButtons(current: badgeColorBinding)
                                
                                Divider()
                                
                                Button("Reset Counter") { badgeCount = 0 }
                            } label: {
                                Label("Badges", systemImage: "1.circle")
                            } primaryAction: {
                                selectedTool = .badge
                                selectedObjectID = nil
                                activeHandle = .none
                                cropDraftRect = nil
                                cropRect = nil
                                cropHandle = .none
                                focusedTextID = nil
                            }
                            .id(badgeColor)
                            .glassEffect(selectedTool == .badge ? .regular.tint(Color(nsColor: badgeColor).opacity(0.7)) : .regular)
                            .help("Click to place numbered badge")
                            
                            // Text Tool
                            Menu {
                                
                                colorButtons(current: textColorBinding)
                                
                                Divider()
                                
                                Menu("Font Size") {
                                    ForEach([10,12,14,16,18,22,26,32,40,48], id: \.self) { s in
                                        Button(action: { textFontSize = CGFloat(s) }) {
                                            if Int(textFontSize) == s { Image(systemName: "checkmark") }
                                            Text("\(s) pt")
                                        }
                                    }
                                }
                                
                                Divider()
                                
                                Toggle("Background", isOn: $textBGEnabled)
                                
                                Menu("Background Color") {
                                    highlightColorButtons(current: textBGColorBinding)
                                }
                                
                                
                            } label: {
                                Label("Text", systemImage: "textformat")
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(selectedTool == .text ? Color.white : Color.primary)
                                    .tint(selectedTool == .text ? .white : .primary)
                            } primaryAction: {
                                selectedTool = .text
                                selectedObjectID = nil; activeHandle = .none; cropDraftRect = nil; cropRect = nil; cropHandle = .none
                            }
                            .id("\(textColor)-\(textBGEnabled)-\(textBGColor)-\(textFontSize)-\(textBGColor)")
                            .glassEffect(selectedTool == .text ? .regular.tint(Color(nsColor: textColor).opacity(0.7)) : .regular)
                            .help("Click to place a text box.")
                            
                            // Rotate Image
                            Menu {
                                Button {
                                    rotateCurrentImage90(clockwise: true)
                                } label: {
                                    Label("Rotate Clockwise", systemImage: "rotate.right")
                                }
                                
                                Button {
                                    rotateCurrentImage90(clockwise: false)
                                } label: {
                                    Label("Rotate Counterclockwise", systemImage: "rotate.left")
                                }
                            } label: {
                                Label("Rotate", systemImage: "rotate.right")
                            } primaryAction: {
                                rotateCurrentImage90(clockwise: true)
                            }
                            .help("Rotate image 90° clockwise")
                            
                            // Crop
                            Button(action: {
                                selectedTool = .crop
                                selectedObjectID = nil
                                activeHandle = .none
                                focusedTextID = nil
                                
                            }) {
                                Label("Crop", systemImage: "crop")
                                    .foregroundStyle(selectedTool == .crop ? Color.white : Color.primary)
                            }
                            .glassEffect(selectedTool == .crop ? .regular.tint(.blue) : .regular)
                            .help("Drag to select an area to crop")
                            
                        }
                    }        else {
                        ToolbarItem(placement: .principal) {
                            Spacer()
                        }
                    }
                    
                    if hasPermissionIssues {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                appDelegate.showPermissionsView = true
                            } label: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .help("Missing permissions required for Screen Snip")
                            }
                        }
                        
                        
                        
        
                    }
        
                    
                    // Capture button (always available)
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            GlobalHotKeyManager.shared.triggerCapture()
                        } label: {
                            Label("Capture", systemImage: "camera.viewfinder")
                        }
                    }
    }
}
