// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Lifecycle state of a `DownloadSegment` (`04-domain-and-data-contracts.md` §4).
///
/// Raw values are stable persistence tokens. The transition table is exhaustive
/// and enforced by `SegmentStateTransitionTests`.
public enum SegmentState: String, CaseIterable, Sendable, Codable {
    case planned
    case connecting
    case active
    case checkpointing
    case retryWaiting
    case complete
    case cancelled

    /// No further transition allowed.
    public static let absolutelyTerminal: Set<SegmentState> = [.complete, .cancelled]

    public func canTransition(to target: SegmentState) -> Bool {
        Self.allowedTargets[self, default: []].contains(target)
    }

    static let allowedTargets: [SegmentState: Set<SegmentState>] = [
        .planned: [.connecting, .cancelled],
        .connecting: [.active, .retryWaiting, .cancelled],
        .active: [.checkpointing, .retryWaiting, .cancelled],
        // §4's cancellation set is planned|connecting|active|retryWaiting; a
        // checkpointing segment finishes its checkpoint (→ complete/active) before
        // it can cancel, so `checkpointing → cancelled` is intentionally excluded.
        .checkpointing: [.complete, .active],
        .retryWaiting: [.connecting, .active, .cancelled],
        .complete: [],
        .cancelled: []
    ]
}
