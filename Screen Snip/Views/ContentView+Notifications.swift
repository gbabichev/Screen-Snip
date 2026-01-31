import SwiftUI
import Combine

extension ContentView {
    // MARK: - Notification Handlers
    
    // Merge all fs into a single stream the view can subscribe to.
    var notificationStream: AnyPublisher<Notification, Never> {
        let nc = NotificationCenter.default
        return Publishers.MergeMany([
            nc.publisher(for: Notification.Name("com.georgebabichev.screenSnip.beginSnipFromIntent")),
            nc.publisher(for: .selectTool),
            nc.publisher(for: .openImageFile),
            nc.publisher(for: .copyToClipboard),
            nc.publisher(for: .performUndo),
            nc.publisher(for: .performRedo),
            nc.publisher(for: .saveImage),
            nc.publisher(for: .saveAsImage),
            nc.publisher(for: .zoomIn),
            nc.publisher(for: .zoomOut),
            nc.publisher(for: .resetZoom),
            nc.publisher(for: .rotateClockwise),
            nc.publisher(for: .rotateCounterclockwise),
            nc.publisher(for: .requestCloseWindow),
        ])
        .eraseToAnyPublisher()
    }
    
    // Central handler so the `.onReceive` body stays tiny.
    func handleAppNotification(_ note: Notification) {
        switch note.name {
        case Notification.Name("com.georgebabichev.screenSnip.beginSnipFromIntent"):
            onBeginSnipFromIntent(note)
            
        case Notification.Name("showPermissionsView"): // Add this case
            appDelegate.showPermissionsView = false
            
        case .selectTool:
            onSelectToolNotification(note)
            
        case .openImageFile:
            onOpenImageFile()
            
        case .copyToClipboard:
            onCopyToClipboard()
            
        case .performUndo:
            onPerformUndo()
            
        case .performRedo:
            onPerformRedo()
            
        case .saveImage:
            onSaveImage()
            
        case .saveAsImage:
            onSaveAsImage()
            
        case .zoomIn, .zoomOut, .resetZoom:
            onZoomNotification(note)
            
        case .rotateClockwise, .rotateCounterclockwise:
            onRotateNotification(note)

        case .requestCloseWindow:
            onRequestCloseWindow(note)
            
        default:
            break
        }
    }
    
    
    func onBeginSnipFromIntent(_ note: Notification) {
        // Extract URL and activation flag from userInfo
        guard let userInfo = note.userInfo,
              let url = userInfo["url"] as? URL else {
            return
        }

        confirmDiscardIfNeeded {
            //let shouldActivate = userInfo["shouldActivate"] as? Bool ?? true
            
            // CRITICAL: Clear ALL existing state first to prevent memory accumulation
            objects.removeAll()
            objectSpaceSize = nil
            selectedObjectID = nil
            activeHandle = .none
            cropRect = nil
            cropDraftRect = nil
            cropHandle = .none
            focusedTextID = nil
            
            // CRITICAL: Clear undo/redo stacks to prevent memory growth
            undoStack.removeAll()
            redoStack.removeAll()
            
            // CRITICAL: Reset all draft states
            draft = nil
            draftRect = nil
            selectedTool = .pointer
            
            // CRITICAL: Clear any missing Snip tracking
            missingSnipURLs.removeAll()
            
            // Refresh the gallery to ensure the new Snip is in our list
            loadExistingSnips()
            
            // Set the selected Snip (this should now work since we refreshed)
            selectedSnipURL = url
            selectedImageSize = probeImageSize(url)
            updateMenuState()
        }
    }
    func onSelectToolNotification(_ note: Notification) {
        guard let raw = note.userInfo?["tool"] as? String else { return }
        print(raw)
        handleSelectTool(raw)
    }
    func onOpenImageFile() {
        confirmDiscardIfNeeded {
            activeImporter = .image
        }
    }
    func onCopyToClipboard() {
        guard selectedSnipURL != nil else { return }
        flattenRefreshAndCopy()
        selectedTool = .pointer
        selectedObjectID = nil
        activeHandle = .none
        cropDraftRect = nil
        cropRect = nil
        cropHandle = .none
        focusedTextID = nil
    }
    func onPerformUndo() { performUndo() }
    func onPerformRedo() { performRedo() }
    func onSaveImage() {
        guard selectedSnipURL != nil else { return }
        flattenAndSaveInPlace()
    }
    func onSaveAsImage() {
        guard selectedSnipURL != nil else { return }
        flattenAndSaveAs()
    }
    func onZoomNotification(_ notification: Notification) {
        switch notification.name {
        case .zoomIn:    zoomLevel = min(zoomLevel * 1.25, 3.0)
        case .zoomOut:   zoomLevel = max(zoomLevel / 1.25, 1.0)
        case .resetZoom: zoomLevel = 1.0
        default: break
        }
    }

    func onRotateNotification(_ notification: Notification) {
        guard selectedSnipURL != nil else { return }
        switch notification.name {
        case .rotateClockwise:
            rotateCurrentImage90(clockwise: true)
        case .rotateCounterclockwise:
            rotateCurrentImage90(clockwise: false)
        default:
            break
        }
    }

    func onRequestCloseWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        confirmDiscardIfNeeded {
            WindowCloseCoordinator.shared.allowClose = true
            window.performClose(nil)
        }
    }
    
}
