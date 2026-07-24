// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import Application
import Foundation

/// Queue one link for download.
///
/// `perform()` stays non-isolated: `FlowIntentEngine` is the main-actor door to the
/// engine, so the single `await` on it is the whole isolation story here.
struct AddDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Download"

    static let description = IntentDescription(
        "Adds a web link to Flow's download queue and returns the download it created.",
        categoryName: "Downloads",
        searchKeywords: ["download", "link", "url", "queue", "save"]
    )

    /// Runs without bringing the window forward — the point of a shortcut is that
    /// it finishes without anyone looking at it.
    static let openAppWhenRun = false

    @Parameter(
        title: "Link",
        description: "The web address to download. Flow downloads http and https links."
    )
    var link: String

    @Parameter(
        title: "File Name",
        description: "Optional name to save the file as. Leave empty to let Flow choose."
    )
    var fileName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$link)") {
            \.$fileName
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<DownloadItemEntity> & ProvidesDialog {
        let request = try FlowIntentInput.validate(link: link, fileName: fileName)
        let added = try await FlowIntentEngine.add(request)
        let entity = DownloadItemEntity(added.download)
        let message = added.fileNameApplied
            ? "Added \(added.download.name) to Flow."
            : "Added \(added.download.name) to Flow, but the file name you chose could not be used."
        return .result(value: entity, dialog: IntentDialog(stringLiteral: message))
    }
}
