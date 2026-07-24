// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Application
import Foundation

/// Drives the Check for Updates menu / Settings button and presents results.
@MainActor
public final class UpdateCheckController: ObservableObject {
    @Published public private(set) var isChecking = false
    @Published public var alertTitle = ""
    @Published public var alertMessage = ""
    @Published public var alertURL: URL?
    @Published public var isAlertPresented = false

    private let checker: UpdateChecker

    public init(checker: UpdateChecker = UpdateChecker()) {
        self.checker = checker
    }

    public func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let result = await checker.check()
            isChecking = false
            present(result)
        }
    }

    public func openAlertURL() {
        guard let url = alertURL else { return }
        NSWorkspace.shared.open(url)
        alertURL = nil
    }

    private func present(_ result: UpdateCheckResult) {
        switch result {
        case let .upToDate(current):
            alertTitle = "You’re up to date"
            alertMessage = "Flow \(current) is the latest release."
            alertURL = nil
        case let .updateAvailable(current, latest, releaseURL):
            alertTitle = "Update available"
            alertMessage =
                "Flow \(latest) is available (you have \(current)). "
                    + "Open the GitHub release to download the new build."
            alertURL = releaseURL
        case let .failed(message):
            alertTitle = "Update check failed"
            alertMessage = message
            alertURL = UpdateChecker.releasesURL
        }
        isAlertPresented = true
    }
}
