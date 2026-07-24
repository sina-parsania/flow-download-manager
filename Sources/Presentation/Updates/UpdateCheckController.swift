// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SharedObservability
import Sparkle
import SwiftUI

/// Sparkle-backed updater for in-app download + install (no browser trip).
@MainActor
public final class UpdateCheckController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    public init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        EngineLog.updater.info("Sparkle updater started")
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
