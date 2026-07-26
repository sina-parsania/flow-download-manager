// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SharedObservability
import Sparkle
import SwiftUI

/// Sparkle-backed updater. Manual “Check for Updates…” is the default path;
/// background checks / silent download are Settings opt-ins (off by default).
///
/// The published feed is `docs/appcast.xml` on GitHub. We download it ourselves
/// (no HTTP cache), write a copy under Application Support, and hand Sparkle a
/// `file://` feed so it never falls back to the stale bundled `appcast.xml`
/// shipped inside older builds.
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
        controller.updater.clearFeedURLFromUserDefaults()
        applyPreferencesFromDefaults()
        EngineLog.updater.info("Sparkle updater started (manual check by default)")
    }

    public func checkForUpdates() {
        Task {
            do {
                let latest = try await AppcastFetch.fetchLatest(from: Self.remoteFeedURLString)
                let installedBuild = AppcastFetch.installedBuild()
                EngineLog.updater.info(
                    "appcast latest=\(latest.shortVersion, privacy: .public) build=\(latest.build, privacy: .public) installedBuild=\(installedBuild, privacy: .public)"
                )
                if latest.build <= installedBuild {
                    presentUpToDate(short: AppcastFetch.installedShortVersion())
                    return
                }
                let feedFile = try AppcastFetch.writeFeedForSparkle(latest.rawXML)
                feedHost.feedURLString = feedFile.absoluteString
                controller.checkForUpdates(nil)
            } catch {
                EngineLog.updater.error(
                    "appcast fetch failed \(EngineLog.redacted(error), privacy: .public)"
                )
                presentFeedUnavailable()
            }
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

    private func presentUpToDate(short: String) {
        alertTitle = "You’re up to date"
        alertMessage = "Flow \(short) is the newest version available from the update feed."
        isAlertPresented = true
    }

    private func presentFeedUnavailable() {
        let short = AppcastFetch.installedShortVersion()
        alertTitle = "Could not check for updates"
        alertMessage =
            "Flow \(short) could not reach the public update feed. "
                + "Install the latest build from GitHub: "
                + "https://github.com/sina-parsania/flow-download-manager/releases/latest"
        isAlertPresented = true
    }

    private func applyPreferencesFromDefaults() {
        let defaults = UserDefaults.standard
        controller.updater.automaticallyChecksForUpdates =
            defaults.bool(forKey: Self.automaticChecksDefaultsKey)
        controller.updater.automaticallyDownloadsUpdates =
            defaults.bool(forKey: Self.automaticDownloadDefaultsKey)
    }
}

/// Holds the live feed URL for Sparkle.
private final class FeedHost: NSObject, SPUUpdaterDelegate {
    var feedURLString: String

    init(feedURLString: String) {
        self.feedURLString = feedURLString
        super.init()
    }

    @objc func feedURLString(for _: SPUUpdater) -> String? {
        feedURLString
    }
}
