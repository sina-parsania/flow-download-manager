// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Pure guard: only terminal jobs may be removed from the library (DB row delete).
public enum DeleteJobGuard {
    /// Completed, failed, and cancelled may be deleted. Active/queued states may not.
    public static func allowsDelete(_ state: JobState) -> Bool {
        JobState.terminalStates.contains(state)
    }

    /// Failed jobs eligible for bulk “Clear Failed”.
    public static func allowsClearFailed(_ state: JobState) -> Bool {
        state == .failed
    }
}
