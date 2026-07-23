// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Destination filename conflict policy from `destination_profiles.conflictPolicy`.
public enum DestinationConflictPolicy: String, Sendable, Equatable {
    case uniquify
    case overwrite
    case fail

    /// Parses stored policy strings. Unknown values and legacy `rename` map to uniquify.
    public static func parse(_ raw: String) -> DestinationConflictPolicy {
        switch raw.lowercased() {
        case "overwrite":
            return .overwrite
        case "fail":
            return .fail
        case "uniquify", "rename":
            return .uniquify
        default:
            return .uniquify
        }
    }
}

/// Action to take when resolving a preferred final destination URL.
public enum DestinationConflictAction: Sendable, Equatable {
    case usePreferred
    case uniquify
    case overwrite
    case fail
}

public enum DestinationConflictResolver {
    /// Selects how to handle `preferred` when a same-named file may already exist.
    public static func action(
        policy: DestinationConflictPolicy,
        destinationExists: Bool
    ) -> DestinationConflictAction {
        guard destinationExists else { return .usePreferred }
        switch policy {
        case .uniquify:
            return .uniquify
        case .overwrite:
            return .overwrite
        case .fail:
            return .fail
        }
    }
}
