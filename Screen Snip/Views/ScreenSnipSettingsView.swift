import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ScreenSnipSettingsView: View {
    @AppStorage("selectedSettingsPane") private var selectedPane = SettingsPane.general.rawValue
    @AppStorage("preferredSaveFormat") private var preferredFormatRaw = SaveFormat.jpeg.rawValue

    private var paneHeight: CGFloat {
        switch SettingsPane(rawValue: selectedPane) ?? .general {
        case .general:
            return 280
        case .capture:
            return 300
        case .saving:
            let format = SaveFormat(rawValue: preferredFormatRaw) ?? .jpeg
            return format == .png ? 350 : 395
        }
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general.rawValue)

            CaptureSettingsPane()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                .tag(SettingsPane.capture.rawValue)

            SavingSettingsPane()
                .tabItem { Label("Saving", systemImage: "externaldrive") }
                .tag(SettingsPane.saving.rawValue)
        }
        .frame(width: 640, height: paneHeight)
        .animation(.easeInOut(duration: 0.18), value: paneHeight)
        .containerBackground(.regularMaterial, for: .window)
    }

    private enum SettingsPane: String {
        case general
        case capture
        case saving
    }
}

private struct GeneralSettingsPane: View {
#if DEBUG
    private static let loginHelperIdentifier = "com.georgebabichev.Screen-Snip-Helper.debug"
#else
    private static let loginHelperIdentifier = "com.georgebabichev.Screen-Snip-Helper"
#endif

    @AppStorage("confirmSaveBeforeLeavingChanges") private var confirmBeforeLeaving = true
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("imageDisplayMode") private var imageDisplayMode = "fit"
    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    var body: some View {
        SettingsPaneLayout {
            SettingsRow(
                "Fit Image to Window",
                subtitle: "Scale the current image to fill the available editor space."
            ) {
                Toggle("", isOn: Binding(
                    get: { imageDisplayMode == "fit" },
                    set: { imageDisplayMode = $0 ? "fit" : "actual" }
                ))
                .toggleStyle(.switch)
            }

            SettingsRow(
                "Confirm Before Leaving Unsaved Changes",
                subtitle: "Ask before switching or closing when edits haven’t been saved."
            ) {
                Toggle("", isOn: $confirmBeforeLeaving)
                    .toggleStyle(.switch)
            }

            Divider().padding(.vertical, 8)

            SettingsRow("Hide Dock Icon", subtitle: "Keep Screen Snip running as a background utility.") {
                Toggle("", isOn: $hideDockIcon)
                    .toggleStyle(.switch)
            }

            SettingsRow("Launch at Login", subtitle: "Start Screen Snip when you log in to your Mac.") {
                Toggle("", isOn: Binding(
                    get: { launchAtLogin },
                    set: updateLaunchAtLogin
                ))
                .toggleStyle(.switch)
            }
        }
        .onAppear(perform: refreshLaunchAtLogin)
        .alert(
            "Couldn’t Update Launch at Login",
            isPresented: Binding(
                get: { loginItemError != nil },
                set: { if !$0 { loginItemError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginItemError ?? "Unknown error")
        }
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.loginItem(identifier: Self.loginHelperIdentifier).status == .enabled
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.loginItem(identifier: Self.loginHelperIdentifier)
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLogin = service.status == .enabled
        } catch {
            refreshLaunchAtLogin()
            loginItemError = error.localizedDescription
        }
    }
}

private struct CaptureSettingsPane: View {
    @AppStorage("captureMode") private var captureModeRaw = CaptureMode.captureWithWindows.rawValue
    @AppStorage("captureType") private var captureTypeRaw = CaptureType.dragToSelect.rawValue
    @AppStorage("captureMagnifierEnabled") private var magnifierEnabled = true

    var body: some View {
        SettingsPaneLayout {
            SettingsRow(
                "Capture Type",
                subtitle: "Select an area, capture a display, or choose an app window."
            ) {
                Picker("", selection: $captureTypeRaw) {
                    ForEach(CaptureType.allCases, id: \.rawValue) { captureType in
                        Text(captureType.title).tag(captureType.rawValue)
                    }
                }
                .frame(width: 210)
            }

            SettingsRow(
                "Capture Shortcut",
                subtitle: "Click the shortcut, then type a new key combination."
            ) {
                SnipHotKeyRecorder()
            }

            Divider().padding(.vertical, 8)

            SettingsRow(
                "Hide Screen Snip During Capture",
                subtitle: "Hide app windows before freezing the screen."
            ) {
                Toggle("", isOn: Binding(
                    get: { captureModeRaw == CaptureMode.captureWithoutWindows.rawValue },
                    set: {
                        captureModeRaw = $0
                            ? CaptureMode.captureWithoutWindows.rawValue
                            : CaptureMode.captureWithWindows.rawValue
                    }
                ))
                .toggleStyle(.switch)
            }
            .disabled(captureTypeRaw == CaptureType.fullWindow.rawValue)

            SettingsRow(
                "Magnify Capture Cursor",
                subtitle: "Show a zoomed-in view beside the orange selection cursor."
            ) {
                Toggle("", isOn: $magnifierEnabled)
                    .toggleStyle(.switch)
            }
            .disabled(captureTypeRaw != CaptureType.dragToSelect.rawValue)
        }
    }
}

private struct SavingSettingsPane: View {
    @AppStorage("preferredSaveFormat") private var preferredFormatRaw = SaveFormat.jpeg.rawValue
    @AppStorage("saveQuality") private var saveQuality = 0.9
    @AppStorage("saveDirectoryPath") private var saveDirectoryPath = ""
    @AppStorage("downsampleToNonRetinaClipboard") private var downsampleClipboard = false
    @AppStorage("downsampleToNonRetinaForSave") private var downsampleSave = false
    @AppStorage("saveOnCopy") private var saveOnCopy = true
    @State private var isChoosingDirectory = false
    @State private var directoryError: String?

    private var preferredFormat: SaveFormat {
        SaveFormat(rawValue: preferredFormatRaw) ?? .jpeg
    }

    private var displayedDirectory: String {
        saveDirectoryPath.isEmpty ? "Pictures/Screen Snip" : saveDirectoryPath
    }

    var body: some View {
        SettingsPaneLayout {
            SettingsRow("Save Location", subtitle: displayedDirectory) {
                HStack(spacing: 8) {
                    Button("Choose…") { isChoosingDirectory = true }

                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        resetSaveDirectory()
                    }
                    .disabled(saveDirectoryPath.isEmpty)
                    .help("Restore Pictures/Screen Snip as the save location")
                }
            }

            SettingsRow("File Format", subtitle: "Choose the default format for new captures.") {
                Picker("", selection: $preferredFormatRaw) {
                    Text("PNG").tag(SaveFormat.png.rawValue)
                    Text("JPG").tag(SaveFormat.jpeg.rawValue)
                    Text("HEIC").tag(SaveFormat.heic.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            if preferredFormat == .jpeg || preferredFormat == .heic {
                SettingsRow("Image Quality") {
                    HStack(spacing: 10) {
                        Slider(value: $saveQuality, in: 0.4...1.0)
                            .frame(width: 170)
                        Text(String(format: "%.0f%%", saveQuality * 100))
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            Divider().padding(.vertical, 8)

            SettingsRow(
                "Downsample Retina Screenshots",
                subtitle: "Save high-resolution captures at standard 1× resolution."
            ) {
                Toggle("", isOn: $downsampleSave)
                    .toggleStyle(.switch)
            }

            SettingsRow(
                "Automatically Save on Copy",
                subtitle: "Save edited images to disk when they’re copied."
            ) {
                Toggle("", isOn: $saveOnCopy)
                    .toggleStyle(.switch)
            }

            SettingsRow(
                "Downsample Retina Screenshots for Copy",
                subtitle: "Copy high-resolution images at standard 1× resolution."
            ) {
                Toggle("", isOn: $downsampleClipboard)
                    .toggleStyle(.switch)
                    .disabled(downsampleSave && saveOnCopy)
            }
        }
        .fileImporter(
            isPresented: $isChoosingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleDirectorySelection
        )
        .alert(
            "Couldn’t Use That Folder",
            isPresented: Binding(
                get: { directoryError != nil },
                set: { if !$0 { directoryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(directoryError ?? "Unknown error")
        }
    }

    private func handleDirectorySelection(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard SecurityScopedResourceManager.shared.activateSaveDirectory(url) else {
                directoryError = "Screen Snip couldn’t access the selected folder."
                return
            }

            let bookmark: Data
            do {
                bookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                SecurityScopedResourceManager.shared.releaseSaveDirectory()
                throw error
            }
            UserDefaults.standard.set(bookmark, forKey: "saveDirectoryBookmark")
            saveDirectoryPath = url.path
        } catch {
            if (error as? CocoaError)?.code != .userCancelled {
                directoryError = error.localizedDescription
            }
        }
    }

    private func resetSaveDirectory() {
        SecurityScopedResourceManager.shared.releaseSaveDirectory()
        UserDefaults.standard.removeObject(forKey: "saveDirectoryBookmark")
        saveDirectoryPath = ""
    }
}

private struct SettingsPaneLayout<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }
}
