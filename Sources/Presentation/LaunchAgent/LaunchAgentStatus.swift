// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ServiceManagement

/// Availability-neutral projection of `SMAppService.Status` used by the UI. The
/// app explains background processing and links to System Settings when approval
/// is required (`bootstrap prompt §4`, `03-design-system-ui-ux.md` §13).
public enum LaunchAgentStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown(Int)

    public init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unknown(status.rawValue)
        }
    }

    /// Short, user-facing headline (localized in the String Catalog at the view).
    public var headline: String {
        switch self {
        case .notRegistered: return "Background engine is off"
        case .enabled: return "Background engine is running"
        case .requiresApproval: return "Approval needed in System Settings"
        case .notFound: return "Background engine not found"
        case .unknown: return "Background engine status unknown"
        }
    }

    public var detail: String {
        switch self {
        case .notRegistered:
            return "Register the engine so transfers continue after you close the window."
        case .enabled:
            return "Transfers continue in the background even when the window is closed."
        case .requiresApproval:
            return "Open Login Items in System Settings and allow Download Manager’s background engine."
        case .notFound:
            return "The engine helper is missing from the app bundle. Reinstall the app."
        case let .unknown(code):
            return "Reported an unrecognized status code (\(code))."
        }
    }

    /// Whether the UI should surface a "Open System Settings" affordance.
    public var needsSystemSettingsApproval: Bool {
        self == .requiresApproval
    }

    /// Whether the engine is usable right now.
    public var isOperational: Bool {
        self == .enabled
    }
}
