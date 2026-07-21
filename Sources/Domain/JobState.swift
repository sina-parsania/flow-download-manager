// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Lifecycle state of a `DownloadJob` (`04-domain-and-data-contracts.md` §3).
///
/// Raw values are the stable persistence tokens (never localized). The transition
/// table is exhaustive and enforced by `JobStateTransitionTests`, which enumerates
/// every ordered pair of states.
public enum JobState: String, CaseIterable, Sendable, Codable {
    case created
    case inspecting
    case awaitingUserSelection
    case ready
    case queued
    case scheduled
    case connecting
    case downloading
    case paused
    case retryWaiting
    case verifying
    case merging
    case postProcessing
    case completed
    case failed
    case cancelled

    /// States that require a terminal reason. `completed` carries NO reason (it is
    /// verified success — see `TerminalReason` and the DB CHECK in `SchemaMigrator`);
    /// only `failed`/`cancelled` require one, and they may re-enter the pipeline
    /// only by creating a new attempt and returning to `ready`/`queued`
    /// (`04-domain-and-data-contracts.md` §3).
    public static let terminalReasonRequiring: Set<JobState> = [.failed, .cancelled]

    /// All terminal completion states (no further active transfer).
    public static let terminalStates: Set<JobState> = [.completed, .failed, .cancelled]

    /// States from which no further transition is allowed at all.
    public static let absolutelyTerminal: Set<JobState> = [.completed]

    /// Whether a transition `self → target` is structurally legal. Command-level
    /// guards (valid input, elapsed retry policy, durable checkpoint) are enforced
    /// separately in the Application layer; this models only structural legality.
    public func canTransition(to target: JobState) -> Bool {
        Self.allowedTargets[self, default: []].contains(target)
    }

    /// The complete adjacency table. Any pair not listed here is forbidden,
    /// including every self-transition.
    static let allowedTargets: [JobState: Set<JobState>] = [
        .created: [.inspecting, .cancelled],
        .inspecting: [.awaitingUserSelection, .ready, .failed, .cancelled],
        .awaitingUserSelection: [.ready, .cancelled, .failed],
        .ready: [.queued, .scheduled, .cancelled],
        .queued: [.connecting, .scheduled, .paused, .cancelled, .failed],
        .scheduled: [.queued, .connecting, .paused, .cancelled],
        .connecting: [.downloading, .retryWaiting, .paused, .failed, .cancelled],
        .downloading: [.verifying, .merging, .paused, .retryWaiting, .failed, .cancelled],
        .paused: [.connecting, .queued, .cancelled, .failed],
        .retryWaiting: [.connecting, .cancelled, .failed],
        // `verifying → completed` is illegal: completion passes finalization and
        // optional post-processing first (`04-domain-and-data-contracts.md` §3).
        .verifying: [.merging, .postProcessing, .retryWaiting, .failed, .cancelled],
        .merging: [.verifying, .postProcessing, .failed, .cancelled],
        // The single path to `completed`.
        .postProcessing: [.completed, .failed, .cancelled],
        .completed: [],
        // Restart-with-new-attempt only.
        .failed: [.ready, .queued],
        .cancelled: [.ready, .queued]
    ]
}
