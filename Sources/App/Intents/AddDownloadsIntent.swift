// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import Application
import Foundation

/// Queue a list of links in one batch.
struct AddDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Downloads"

    static let description = IntentDescription(
        "Adds several web links to Flow's download queue and returns the downloads it created.",
        categoryName: "Downloads",
        searchKeywords: ["download", "links", "batch", "queue", "list"]
    )

    static let openAppWhenRun = false

    @Parameter(
        title: "Links",
        description: "The web addresses to download. Flow downloads http and https links."
    )
    var links: [String]

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$links)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[DownloadItemEntity]> & ProvidesDialog {
        let batch = try FlowIntentInput.validate(links: links)
        let downloads = try await FlowIntentEngine.add(batch.accepted)
        let entities = downloads.map(DownloadItemEntity.init)
        return .result(value: entities, dialog: IntentDialog(stringLiteral: Self.message(for: batch)))
    }

    /// Says what was queued and, when anything was dropped, that it was dropped.
    /// A skipped link that nobody is told about is a link somebody expects to find.
    private static func message(for batch: ValidatedDownloadBatch) -> String {
        let added = "Added \(batch.accepted.count) download(s) to Flow."
        guard batch.skippedCount > 0 else { return added }
        return "\(added) \(batch.skippedCount) link(s) were skipped because Flow cannot download them."
    }
}
