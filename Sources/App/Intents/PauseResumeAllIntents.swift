// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import Foundation

/// Pause everything that is running, queued or waiting to retry.
struct PauseAllDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause All Downloads"

    static let description = IntentDescription(
        "Pauses every download Flow is running or waiting to run.",
        categoryName: "Downloads",
        searchKeywords: ["pause", "stop", "hold", "downloads"]
    )

    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = try await FlowIntentEngine.pauseAll()
        let message = count == 0
            ? "Nothing was running, so there was nothing to pause."
            : "Paused \(count) download(s)."
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// Resume everything that is paused.
struct ResumeAllDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume All Downloads"

    static let description = IntentDescription(
        "Puts every paused download back in Flow's queue.",
        categoryName: "Downloads",
        searchKeywords: ["resume", "continue", "start", "downloads"]
    )

    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = try await FlowIntentEngine.resumeAll()
        let message = count == 0
            ? "Nothing was paused, so there was nothing to resume."
            : "Resumed \(count) download(s)."
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}
