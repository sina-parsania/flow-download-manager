// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SharedObservability
import Sparkle
import SwiftUI

/// Sparkle-backed updater. Manual “Check for Updates…” is the default path;
/// background checks / silent download are Settings opt-ins (off by default).
@MainActor
public final class UpdateCheckController: ObservableObject {
    public static let automaticChecksDefaultsKey = "SUEnableAutomaticChecks"
    public static let automaticDownloadDefaultsKey = "SUAutomaticallyUpdate"

    private let controller: SPUStandardUpdaterController

    public init() {
        // Info.plist defaults are false; register so first launch never enables auto paths.
        UserDefaults.standard.register(defaults: [
            Self.automaticChecksDefaultsKey: false,
            Self.automaticDownloadDefaultsKey: false
        ])
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        applyPreferencesFromDefaults()
        EngineLog.updater.info("Sparkle updater started (manual check by default)")
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.automaticChecksDefaultsKey)
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    public func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.automaticDownloadDefaultsKey)
        controller.updater.automaticallyDownloadsUpdates = enabled
    }

    private func applyPreferencesFromDefaults() {
        let defaults = UserDefaults.standard
        controller.updater.automaticallyChecksForUpdates =
            defaults.bool(forKey: Self.automaticChecksDefaultsKey)
        controller.updater.automaticallyDownloadsUpdates =
            defaults.bool(forKey: Self.automaticDownloadDefaultsKey)
    }
}
