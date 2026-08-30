import Foundation

/// Owns the app's long-lived security-scoped resources.
///
/// A scope is started at most once for the configured save directory and once
/// for the currently imported external image. Replacing either resource stops
/// the previous scope, and application termination stops everything.
@MainActor
final class SecurityScopedResourceManager {
    static let shared = SecurityScopedResourceManager()

    private var saveDirectoryURL: URL?
    private var saveDirectoryScopeStarted = false
    private var importedImageURL: URL?
    private var importedImageScopeStarted = false

    private var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private init() {}

    func configuredSaveDirectory() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "saveDirectoryBookmark") else {
            releaseSaveDirectory()
            return nil
        }

        do {
            var isStale = false
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL

            if saveDirectoryURL == resolvedURL {
                return resolvedURL
            }

            guard activateSaveDirectory(resolvedURL) else { return nil }

            if isStale,
               let refreshedBookmark = try? resolvedURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
               ) {
                UserDefaults.standard.set(refreshedBookmark, forKey: "saveDirectoryBookmark")
            }

            return resolvedURL
        } catch {
            print("Failed to resolve save-directory bookmark: \(error)")
            releaseSaveDirectory()
            return nil
        }
    }

    @discardableResult
    func activateSaveDirectory(_ url: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL
        if saveDirectoryURL == normalizedURL { return true }

        releaseSaveDirectory()
        let scopeStarted = normalizedURL.startAccessingSecurityScopedResource()
        guard scopeStarted || !isSandboxed else {
            print("Failed to access the selected save directory")
            return false
        }

        saveDirectoryURL = normalizedURL
        saveDirectoryScopeStarted = scopeStarted
        return true
    }

    func releaseSaveDirectory() {
        if saveDirectoryScopeStarted {
            saveDirectoryURL?.stopAccessingSecurityScopedResource()
        }
        saveDirectoryURL = nil
        saveDirectoryScopeStarted = false
    }

    @discardableResult
    func activateImportedImage(_ url: URL) -> Bool {
        let normalizedURL = url.standardizedFileURL
        if importedImageURL == normalizedURL { return true }

        releaseImportedImage()
        let scopeStarted = normalizedURL.startAccessingSecurityScopedResource()
        guard scopeStarted || !isSandboxed else {
            print("Failed to access the selected image")
            return false
        }

        importedImageURL = normalizedURL
        importedImageScopeStarted = scopeStarted
        return true
    }

    func releaseImportedImage() {
        if importedImageScopeStarted {
            importedImageURL?.stopAccessingSecurityScopedResource()
        }
        importedImageURL = nil
        importedImageScopeStarted = false
    }

    func releaseAll() {
        releaseSaveDirectory()
        releaseImportedImage()
    }
}
