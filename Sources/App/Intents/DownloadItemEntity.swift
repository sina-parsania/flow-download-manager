// SPDX-License-Identifier: GPL-3.0-or-later

import AppIntents
import Domain
import Foundation

/// A download, as Shortcuts sees it.
///
/// The exposed properties are what a shortcut can branch on: `status` is
/// `JobState.displayName`, so "If Status is Paused" reads the same wording the
/// library window shows and never a persistence token.
struct DownloadItemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Download"
    static let defaultQuery = DownloadItemQuery()

    let id: String

    @Property(title: "Name")
    var name: String

    @Property(title: "Status")
    var status: String

    @Property(title: "Link")
    var link: String

    @Property(title: "Percent Complete")
    var percentComplete: Int

    @Property(title: "Bytes Received")
    var bytesReceived: Int

    init(_ snapshot: DownloadIntentSnapshot) {
        id = snapshot.id
        name = snapshot.name
        status = snapshot.status
        link = snapshot.link
        percentComplete = snapshot.percentComplete
        bytesReceived = snapshot.bytesReceived
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(status)")
    }
}

/// Resolves downloads by identifier for Shortcuts, and offers the current library
/// as suggestions when someone picks a download by hand.
struct DownloadItemQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DownloadItemEntity] {
        let wanted = Set(identifiers)
        return try await FlowIntentEngine.downloads()
            .filter { wanted.contains($0.id) }
            .map(DownloadItemEntity.init)
    }

    func suggestedEntities() async throws -> [DownloadItemEntity] {
        try await FlowIntentEngine.downloads()
            .prefix(DownloadItemQuery.suggestionLimit)
            .map(DownloadItemEntity.init)
    }

    /// Enough to pick from without turning the picker into the whole library.
    private static let suggestionLimit = 20
}

/// Which downloads a shortcut wants back.
enum DownloadFilter: String, AppEnum {
    case all
    case active
    case waiting
    case finished
    case unfinished

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Download Filter"

    static let caseDisplayRepresentations: [DownloadFilter: DisplayRepresentation] = [
        .all: "All downloads",
        .active: "Downloading now",
        .waiting: "Waiting or paused",
        .finished: "Completed",
        .unfinished: "Failed or cancelled"
    ]

    /// Whether a state belongs in this filter.
    ///
    /// Grouping lives here rather than in `Domain` because it is presentation
    /// vocabulary — "waiting" is what a person calls the queue, not a lifecycle
    /// stage the state machine knows about.
    func includes(_ state: JobState) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return Self.activeStates.contains(state)
        case .waiting:
            return Self.waitingStates.contains(state)
        case .finished:
            return state == .completed
        case .unfinished:
            return state == .failed || state == .cancelled
        }
    }

    private static let activeStates: Set<JobState> = [
        .connecting, .downloading, .verifying, .merging, .postProcessing
    ]

    private static let waitingStates: Set<JobState> = [
        .created, .inspecting, .awaitingUserSelection, .ready,
        .queued, .scheduled, .paused, .retryWaiting
    ]
}
