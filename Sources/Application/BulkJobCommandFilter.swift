// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Pure filters for Pause All / Resume All (which states receive which command).
public enum BulkJobCommandFilter {
    /// Active / queued / scheduled jobs that can be paused.
    public static func shouldReceivePause(_ state: JobState) -> Bool {
        switch state {
        case .queued, .connecting, .downloading, .scheduled, .retryWaiting:
            return true
        default:
            return false
        }
    }

    /// Paused jobs that can be resumed back to the queue.
    public static func shouldReceiveResume(_ state: JobState) -> Bool {
        state == .paused
    }
}
