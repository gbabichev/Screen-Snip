import Foundation
import Darwin

extension Notification.Name {
    static let snipDirectoryDidChange = Notification.Name(
        "com.georgebabichev.screenSnip.snipDirectoryDidChange"
    )
}

/// Watches the active Snips directory without polling. Directory writes are
/// intentionally debounced because a single image save may emit several events.
nonisolated final class SnipDirectoryWatcher: @unchecked Sendable {
    static let shared = SnipDirectoryWatcher()

    private let queue = DispatchQueue(
        label: "com.georgebabichev.Screen-Snip.snip-directory-watcher",
        qos: .utility
    )
    private var source: DispatchSourceFileSystemObject?
    private var watchedDirectory: URL?
    private var pendingNotification: DispatchWorkItem?

    private init() {}

    func watch(directory: URL) {
        let normalizedDirectory = directory.standardizedFileURL
        queue.async { [weak self] in
            self?.replaceWatcherIfNeeded(with: normalizedDirectory)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func replaceWatcherIfNeeded(with directory: URL) {
        guard watchedDirectory != directory || source == nil else { return }
        stopLocked()

        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )

        watchedDirectory = directory
        source = newSource

        newSource.setEventHandler { [weak self, weak newSource] in
            guard let self, let newSource else { return }
            let directoryNeedsRearming = !newSource.data.intersection([.delete, .rename, .revoke]).isEmpty
            if directoryNeedsRearming {
                newSource.cancel()
                self.source = nil
                self.watchedDirectory = nil
            }
            self.scheduleChangeNotification(for: directory)
        }
        newSource.setCancelHandler {
            close(descriptor)
        }
        newSource.resume()
    }

    private func scheduleChangeNotification(for directory: URL) {
        pendingNotification?.cancel()

        let notification = DispatchWorkItem {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .snipDirectoryDidChange,
                    object: directory
                )
            }
        }
        pendingNotification = notification
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: notification)
    }

    private func stopLocked() {
        pendingNotification?.cancel()
        pendingNotification = nil
        source?.cancel()
        source = nil
        watchedDirectory = nil
    }
}
