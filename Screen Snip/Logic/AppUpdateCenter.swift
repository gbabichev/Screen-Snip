//
//  AppUpdateCenter.swift
//  Zippy
//
//  Created by Codex on 2/18/26.
//
//  Purpose:
//  Provides a reusable app-level update check flow backed by GitHub tags,
//  including launch-time checks and manual checks from menu/About surfaces.

import AppKit
import Combine
import Foundation

/// Main-actor coordinator for "Check for Updates" behavior across the app.
@MainActor
final class AppUpdateCenter: ObservableObject {
    static let shared = AppUpdateCenter()

    @Published private(set) var isChecking = false
    @Published private(set) var lastStatusMessage: String?

    private var activeCheckTask: Task<Void, Never>?
    private let checker = GitHubTagUpdateChecker()

    private init() {}

    func checkForUpdates(trigger: UpdateCheckTrigger = .manual) {
        guard activeCheckTask == nil else {
            return
        }

        guard let configuration = AppUpdateConfiguration.current() else {
            let message = "Update checking is not configured for this app."
            lastStatusMessage = message
            if trigger == .manual {
                presentInfoAlert(title: "Check for Updates", message: message)
            }
            return
        }

        isChecking = true
        lastStatusMessage = "Checking for updates..."

        activeCheckTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.isChecking = false
                self.activeCheckTask = nil
            }

            do {
                let latestVersion = try await checker.latestTagName(
                    owner: configuration.owner,
                    repository: configuration.repository,
                    userAgent: configuration.appName
                )

                let currentVersion = configuration.currentVersion
                let isNewer = VersionStringComparator.isVersion(latestVersion, greaterThan: currentVersion)

                if isNewer {
                    let message = "Version \(latestVersion) is available. You have \(currentVersion)."
                    self.lastStatusMessage = message

                    let releaseURL = configuration.releaseURL(for: latestVersion)
                    self.presentUpdateAvailableAlert(
                        appName: configuration.appName,
                        message: message,
                        releaseURL: releaseURL
                    )
                    return
                }

                let message = "You're up to date (\(currentVersion))."
                self.lastStatusMessage = message

                if trigger == .manual {
                    self.presentInfoAlert(title: "Check for Updates", message: message)
                }
            } catch {
                let message = "Could not check for updates. \(error.localizedDescription)"
                self.lastStatusMessage = message

                if trigger == .manual {
                    self.presentInfoAlert(title: "Check for Updates", message: message)
                }
            }
        }
    }

    private func presentUpdateAvailableAlert(appName: String, message: String, releaseURL: URL?) {
        let alert = NSAlert()
        alert.messageText = "A New \(appName) Update Is Available"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: releaseURL == nil ? "OK" : "Open Download Page")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn, let releaseURL else {
            return
        }

        NSWorkspace.shared.open(releaseURL)
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Describes how an update check was initiated.
enum UpdateCheckTrigger: Sendable {
    case automaticLaunch
    case manual
}

/// Info.plist-backed update configuration so this helper can be reused in other apps.
private struct AppUpdateConfiguration: Sendable {
    let appName: String
    let currentVersion: String
    let owner: String
    let repository: String
    let releasesPageURL: URL?

    func releaseURL(for tag: String) -> URL? {
        guard let releasesPageURL else {
            return URL(string: "https://github.com/\(owner)/\(repository)/releases/tag/\(tag)")
        }

        let pathParts = releasesPageURL.pathComponents.filter { $0 != "/" }
        if pathParts.contains("releases") {
            return releasesPageURL.appendingPathComponent("tag").appendingPathComponent(tag)
        }

        return releasesPageURL
            .appendingPathComponent("releases")
            .appendingPathComponent("tag")
            .appendingPathComponent(tag)
    }

    nonisolated static func current(bundle: Bundle = .main) -> AppUpdateConfiguration? {
        let info = bundle.infoDictionary ?? [:]

        guard
            let releasesURLString = (info["UpdateCheckReleasesURL"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !releasesURLString.isEmpty,
            let releasesPageURL = URL(string: releasesURLString),
            let (owner, repository) = githubOwnerRepository(from: releasesPageURL)
        else {
            return nil
        }

        let appName = (info["CFBundleDisplayName"] as? String) ??
            (info["CFBundleName"] as? String) ??
            "This app"
        let currentVersion = (info["CFBundleShortVersionString"] as? String) ??
            (info["CFBundleVersion"] as? String) ??
            "0"

        return AppUpdateConfiguration(
            appName: appName,
            currentVersion: currentVersion,
            owner: owner,
            repository: repository,
            releasesPageURL: releasesPageURL
        )
    }

    private nonisolated static func githubOwnerRepository(from url: URL) -> (String, String)? {
        guard
            let host = url.host?.lowercased(),
            host.contains("github")
        else {
            return nil
        }

        let pathParts = url.pathComponents
            .filter { $0 != "/" && !$0.isEmpty }
        guard pathParts.count >= 2 else {
            return nil
        }

        let owner = pathParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = pathParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !repository.isEmpty else {
            return nil
        }

        return (owner, repository)
    }
}

/// Lightweight GitHub tags API client used for update checks.
private struct GitHubTagUpdateChecker {
    private struct GitHubTag: Decodable, Sendable {
        let name: String
    }

    private enum UpdateCheckError: LocalizedError {
        case invalidResponse
        case noTagsFound

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Received an invalid response from GitHub."
            case .noTagsFound:
                return "No release tags were found for this repository."
            }
        }
    }

    func latestTagName(owner: String, repository: String, userAgent: String) async throws -> String {
        guard var components = URLComponents(string: "https://api.github.com/repos/\(owner)/\(repository)/tags") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw UpdateCheckError.invalidResponse
        }

        let tags = try JSONDecoder().decode([GitHubTag].self, from: data)
        guard !tags.isEmpty else {
            throw UpdateCheckError.noTagsFound
        }

        let latestTag = tags.max(by: { lhs, rhs in
            VersionStringComparator.isVersion(rhs.name, greaterThan: lhs.name)
        }) ?? tags[0]

        return latestTag.name
    }
}

/// Semantic-ish version comparator that tolerates common GitHub tag formats.
private enum VersionStringComparator {
    nonisolated static func isVersion(_ lhs: String, greaterThan rhs: String) -> Bool {
        let lhsComponents = numericComponents(from: lhs)
        let rhsComponents = numericComponents(from: rhs)
        let maxCount = max(lhsComponents.count, rhsComponents.count)

        for index in 0..<maxCount {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }

        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedDescending
    }

    private nonisolated static func numericComponents(from rawVersion: String) -> [Int] {
        let trimmed = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let noPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V") ? String(trimmed.dropFirst()) : trimmed
        let base = noPrefix.split(whereSeparator: { character in
            !(character.isNumber || character == ".")
        }).first ?? Substring("")

        let parts = base.split(separator: ".")
        let numericParts = parts.compactMap { Int($0) }
        if !numericParts.isEmpty {
            return numericParts
        }

        let digitsOnly = noPrefix.filter(\.isNumber)
        if let number = Int(digitsOnly) {
            return [number]
        }

        return [0]
    }
}
