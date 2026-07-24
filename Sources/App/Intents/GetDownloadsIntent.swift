// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import Foundation

/// Read the current library so a shortcut can branch on it.
struct GetDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Downloads"

    static let description = IntentDescription(
        "Returns Flow's downloads with their status, so a shortcut can check on them.",
        categoryName: "Downloads",
        searchKeywords: ["downloads", "status", "list", "progress", "check"]
    )

    static let openAppWhenRun = false

    @Parameter(title: "Include", default: .all)
    var filter: DownloadFilter

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$filter) from Flow")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[DownloadItemEntity]> {
        let chosen = filter
        let downloads = try await FlowIntentEngine.downloads()
            .filter { chosen.includes($0.state) }
        return .result(value: downloads.map(DownloadItemEntity.init))
    }
}
