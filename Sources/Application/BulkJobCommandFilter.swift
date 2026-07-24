// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Which job states may receive which Library / toolbar / context-menu commands.
/// Single source for Pause All, per-row menus, and multi-select enablement.
public enum BulkJobCommandFilter {
    public static func canPause(_ state: JobState) -> Bool {
        switch state {
        case .queued, .connecting, .downloading, .scheduled, .ready,
             .retryWaiting, .verifying, .merging, .postProcessing:
            return true
        default:
            return false
        }
    }

    public static func canResume(_ state: JobState) -> Bool {
        state == .paused || state == .retryWaiting
    }

    public static func canCancel(_ state: JobState) -> Bool {
        !JobState.terminalStates.contains(state)
    }

    public static func canRetry(_ state: JobState) -> Bool {
        state == .failed || state == .cancelled
    }

    public static func canRestart(_ state: JobState) -> Bool {
        state == .paused || state == .failed || state == .cancelled
    }

    public static func canRemove(_ state: JobState) -> Bool {
        DeleteJobGuard.allowsDelete(state)
    }

    /// Active / queued / scheduled jobs that can be paused (Pause All).
    public static func shouldReceivePause(_ state: JobState) -> Bool {
        canPause(state)
    }

    /// Paused jobs that can be resumed back to the queue (Resume All).
    public static func shouldReceiveResume(_ state: JobState) -> Bool {
        canResume(state)
    }

    public static func anyCanPause(_ states: some Sequence<JobState>) -> Bool {
        states.contains(where: canPause)
    }

    public static func anyCanResume(_ states: some Sequence<JobState>) -> Bool {
        states.contains(where: canResume)
    }

    public static func anyCanCancel(_ states: some Sequence<JobState>) -> Bool {
        states.contains(where: canCancel)
    }

    public static func anyCanRetry(_ states: some Sequence<JobState>) -> Bool {
        states.contains(where: canRetry)
    }

    public static func anyCanRestart(_ states: some Sequence<JobState>) -> Bool {
        states.contains(where: canRestart)
    }

    public static func anyCanRemove(_ states: some Sequence<JobState>) -> Bool {
        states.contains(where: canRemove)
    }
}
