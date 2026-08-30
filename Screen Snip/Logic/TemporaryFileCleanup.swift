import Foundation

enum TemporaryFileCleanup {
    private static let legacyCleanupDefaultsKey = "didCleanupLegacyAsyncImageDownloadsV1"
    private static let legacyFilePrefix = "CFNetworkDownload_"
    private static let legacyFileExtension = "tmp"

    /// Removes files left by the previous AsyncImage-based local image loader.
    /// This runs once because new image loads no longer use CFNetwork.
    @discardableResult
    static func removeLegacyAsyncImageDownloads(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Int {
        guard !defaults.bool(forKey: legacyCleanupDefaultsKey) else { return 0 }

        let temporaryDirectory = fileManager.temporaryDirectory.standardizedFileURL
        guard let items = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var removedCount = 0
        var removalFailed = false

        for item in items {
            let name = item.lastPathComponent
            guard name.hasPrefix(legacyFilePrefix),
                  item.pathExtension.lowercased() == legacyFileExtension,
                  (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }

            do {
                try fileManager.removeItem(at: item)
                removedCount += 1
            } catch {
                removalFailed = true
            }
        }

        if !removalFailed {
            defaults.set(true, forKey: legacyCleanupDefaultsKey)
        }

        return removedCount
    }
}
