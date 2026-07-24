// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SharedObservability
import Sparkle
import SwiftUI

/// Sparkle-backed updater. Manual “Check for Updates…” is the default path;
/// background checks / silent download are Settings opt-ins (off by default).
///
/// If the published GitHub appcast is missing (e.g. not pushed yet), Sparkle
/// uses the appcast bundled in the app so the user sees “up to date” instead of
/// a retrieval error.
@MainActor
public final class UpdateCheckController: ObservableObject {
    public static let automaticChecksDefaultsKey = "SUEnableAutomaticChecks"
    public static let automaticDownloadDefaultsKey = "SUAutomaticallyUpdate"
    public static let remoteFeedURLString =
        "https://raw.githubusercontent.com/sina-parsania/flow-download-manager/main/docs/appcast.xml"

    private let feedHost: FeedHost
    private let controller: SPUStandardUpdaterController

    public init() {
        // Info.plist defaults are false; register so first launch never enables auto paths.
        UserDefaults.standard.register(defaults: [
            Self.automaticChecksDefaultsKey: false,
            Self.automaticDownloadDefaultsKey: false
        ])
        let feedHost = FeedHost(feedURLString: Self.remoteFeedURLString)
        self.feedHost = feedHost
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: feedHost,
            userDriverDelegate: nil
        )
        applyPreferencesFromDefaults()
        EngineLog.updater.info("Sparkle updater started (manual check by default)")
        Task { await refreshResolvedFeedURL() }
    }

    public func checkForUpdates() {
        Task {
            await refreshResolvedFeedURL()
            controller.checkForUpdates(nil)
        }
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.automaticChecksDefaultsKey)
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    public func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.automaticDownloadDefaultsKey)
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    // MARK: Private

    private func applyPreferencesFromDefaults() {
        let defaults = UserDefaults.standard
        controller.updater.automaticallyChecksForUpdates =
            defaults.bool(forKey: Self.automaticChecksDefaultsKey)
        controller.updater.automaticallyDownloadsUpdates =
            defaults.bool(forKey: Self.automaticDownloadDefaultsKey)
    }

    private func refreshResolvedFeedURL() async {
        feedHost.feedURLString = await Self.resolveFeedURLString()
    }

    private static func resolveFeedURLString() async -> String {
        if await remoteFeedIsReachable() {
            return remoteFeedURLString
        }
        if let bundled = Bundle.main.url(forResource: "appcast", withExtension: "xml") {
            EngineLog.updater.info("remote appcast unavailable; using bundled feed")
            return bundled.absoluteString
        }
        EngineLog.updater.error("no remote or bundled appcast available")
        return remoteFeedURLString
    }

    private static func remoteFeedIsReachable() async -> Bool {
        guard let url = URL(string: remoteFeedURLString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Flow/0.2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode),
                  !data.isEmpty
            else { return false }
            return true
        } catch {
            EngineLog.updater.error(
                "remote appcast probe failed \(EngineLog.redacted(error), privacy: .public)"
            )
            return false
        }
    }
}

/// Holds the live feed URL for Sparkle; kept off ``UpdateCheckController`` so we
/// can pass `self` as the updater delegate during initialization.
private final class FeedHost: NSObject, SPUUpdaterDelegate {
    var feedURLString: String

    init(feedURLString: String) {
        self.feedURLString = feedURLString
        super.init()
    }

    func feedURLString(for _: SPUUpdater) -> String? {
        feedURLString
    }
}
