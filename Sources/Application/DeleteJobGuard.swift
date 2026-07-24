// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Pure guard for library removal (DB row delete ± optional on-disk wipe).
public enum DeleteJobGuard {
    /// Any job may be removed from the library. Active transfers are aborted by
    /// the engine before the row is deleted; partial/final files are only wiped
    /// when the caller passes `deleteFiles: true`.
    public static func allowsDelete(_ state: JobState) -> Bool {
        _ = state
        return true
    }

    /// Failed jobs eligible for bulk “Clear Failed”.
    public static func allowsClearFailed(_ state: JobState) -> Bool {
        state == .failed
    }
}
