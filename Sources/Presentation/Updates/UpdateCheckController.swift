// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SharedObservability
import Sparkle
import SwiftUI

/// Sparkle-backed updater. Manual “Check for Updates…” is the default path;
/// background checks / silent download are Settings opt-ins (off by default).
///
/// The published feed lives on GitHub (`docs/appcast.xml`). Until that file is
/// on `origin/main`, a manual check shows a local “up to date” alert instead of
/// Sparkle’s retrieval error (Sparkle cannot use a `file://` feed reliably).
@MainActor
public final class UpdateCheckController: ObservableObject {
    public static let automaticChecksDefaultsKey = "SUEnableAutomaticChecks"
    public static let automaticDownloadDefaultsKey = "SUAutomaticallyUpdate"
    public static let remoteFeedURLString =
        "https://raw.githubusercontent.com/sina-parsania/flow-download-manager/main/docs/appcast.xml"

    @Published public var isAlertPresented = false
    @Published public var alertTitle = ""
    @Published public var alertMessage = ""

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
        // Drop any stale feed URL Sparkle may have persisted in defaults.
        controller.updater.clearFeedURLFromUserDefaults()
        applyPreferencesFromDefaults()
        Self.clearRemoteFeedHTTPCache()
        EngineLog.updater.info("Sparkle updater started (manual check by default)")
    }

    public func checkForUpdates() {
        Task {
            Self.clearRemoteFeedHTTPCache()
            let remoteOK = await Self.remoteFeedIsReachable()
            if remoteOK {
                feedHost.feedURLString = Self.remoteFeedURLString
                controller.checkForUpdates(nil)
                return
            }
            EngineLog.updater.info("remote appcast unavailable; showing local up-to-date alert")
            presentLocalUpToDate()
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

    private func presentLocalUpToDate() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "this build"
        alertTitle = "You’re up to date"
        alertMessage =
            "Flow \(current) is the newest build available to this copy. "
                + "The public update feed is not online yet (push docs/appcast.xml to GitHub to enable remote checks)."
        isAlertPresented = true
    }

    private func applyPreferencesFromDefaults() {
        let defaults = UserDefaults.standard
        controller.updater.automaticallyChecksForUpdates =
            defaults.bool(forKey: Self.automaticChecksDefaultsKey)
        controller.updater.automaticallyDownloadsUpdates =
            defaults.bool(forKey: Self.automaticDownloadDefaultsKey)
    }

    private static func clearRemoteFeedHTTPCache() {
        guard let url = URL(string: remoteFeedURLString) else { return }
        URLCache.shared.removeCachedResponse(for: URLRequest(url: url))
        HTTPCookieStorage.shared.cookies(for: url)?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }

    private static func remoteFeedIsReachable() async -> Bool {
        guard let url = URL(string: remoteFeedURLString) else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.setValue("Flow/0.3.3", forHTTPHeaderField: "User-Agent")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode),
                  !data.isEmpty
            else { return false }
            // Require a parseable RSS root so a soft-404 HTML body cannot pass.
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.contains("<rss") && text.contains("sparkle")
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
