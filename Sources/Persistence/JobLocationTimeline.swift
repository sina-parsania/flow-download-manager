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

    /// Recomputes the displayed location from the profile, **including the job's
    /// category subfolder**.
    ///
    /// This runs on every state transition, so it is the last word on
    /// `destinationPath`. Resolving the profile alone would write the parent back
    /// over a stamped subfolder on the very next transition, and the Location
    /// column would point somewhere the file is not — which is the one thing the
    /// stored path exists to prevent.
    public static func refreshDestinationPath(
        _ job: inout JobRecord,
        profile: DestinationProfileRecord
    ) {
        guard let path = DestinationBookmark.pathDisplay(bookmarkData: profile.bookmarkData) else {
            return
        }
        guard let subfolder = job.categorySubfolder else {
            job.destinationPath = path
            return
        }
        job.destinationPath = (path as NSString).appendingPathComponent(subfolder)
    }
}
