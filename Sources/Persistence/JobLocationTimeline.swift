// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Side effects on job timeline / location fields when the state machine moves.
public enum JobLocationTimeline {
    public static func applyStateTransition(
        _ job: inout JobRecord,
        from previous: JobState,
        to state: JobState,
        at now: Date = Date()
    ) {
        // Retry / restart leave a terminal state; clear Finished so the next
        // completion stamps a fresh end time.
        if JobState.terminalStates.contains(previous),
           !JobState.terminalStates.contains(state) {
            job.completedAt = nil
        }
        if job.startedAt == nil, state == .connecting || state == .downloading {
            job.startedAt = now
        }
        if job.completedAt == nil, JobState.terminalStates.contains(state) {
            job.completedAt = now
        }
    }

    /// Restart-from-scratch: Started should reflect the new attempt.
    public static func clearForRestart(_ job: inout JobRecord) {
        job.startedAt = nil
        job.completedAt = nil
    }

    public static func refreshDestinationPath(
        _ job: inout JobRecord,
        profile: DestinationProfileRecord
    ) {
        if let path = DestinationBookmark.pathDisplay(bookmarkData: profile.bookmarkData) {
            job.destinationPath = path
        }
    }
}
