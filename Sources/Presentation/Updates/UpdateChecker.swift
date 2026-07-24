// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import SharedObservability

/// Outcome of an explicit user-initiated check against GitHub Releases.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String, releaseURL: URL)
    case failed(message: String)
}

/// Community-path update probe: compares the running short version to the latest
/// GitHub Release tag. Does not download or install — opens the release page when
/// the user chooses. Sparkle remains deferred (Track B / signed builds).
public struct UpdateChecker: Sendable {
    public static let releasesURL = mustURL(
        "https://github.com/sina-parsania/flow-download-manager/releases"
    )
    public static let latestAPIURL = mustURL(
        "https://api.github.com/repos/sina-parsania/flow-download-manager/releases/latest"
    )

    private let session: URLSession
    private let currentVersionProvider: @Sendable () -> String

    public init(
        session: URLSession = .shared,
        currentVersionProvider: @escaping @Sendable () -> String = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        }
    ) {
        self.session = session
        self.currentVersionProvider = currentVersionProvider
    }

    public func check() async -> UpdateCheckResult {
        let currentRaw = currentVersionProvider()
        guard let current = AppVersion.parse(currentRaw) else {
            return .failed(message: "Could not read the installed version.")
        }

        var request = URLRequest(url: Self.latestAPIURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Flow/\(current.displayString)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(message: "Unexpected response while checking for updates.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                EngineLog.updater.error(
                    "update check HTTP \(http.statusCode, privacy: .public)"
                )
                if http.statusCode == 404 {
                    return .failed(message: "No published releases were found yet.")
                }
                return .failed(message: "GitHub returned an error while checking for updates.")
            }

            let release = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
            guard let latest = AppVersion.parse(release.tagName) else {
                return .failed(message: "Could not parse the latest release version.")
            }

            EngineLog.updater.info(
                "update check current=\(current.displayString, privacy: .public) latest=\(latest.displayString, privacy: .public)"
            )

            if latest > current {
                let url = release.htmlURL.flatMap(URL.init(string:)) ?? Self.releasesURL
                return .updateAvailable(
                    current: current.displayString,
                    latest: latest.displayString,
                    releaseURL: url
                )
            }
            return .upToDate(current: current.displayString)
        } catch {
            EngineLog.updater.error(
                "update check failed \(EngineLog.redacted(error), privacy: .public)"
            )
            return .failed(message: "Could not reach GitHub to check for updates.")
        }
    }
}

private struct GitHubLatestRelease: Decodable, Sendable {
    let tagName: String
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

private func mustURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
        preconditionFailure("invalid constant URL")
    }
    return url
}
