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
        case .notRegistered: return "Background engine starting…"
        case .enabled: return "Background engine is on"
        case .requiresApproval: return "Approval needed in System Settings"
        case .notFound: return "Background engine starting…"
        case .unknown: return "Background engine status unknown"
        }
    }

    public var detail: String {
        switch self {
        case .notRegistered:
            return "Flow keeps the transfer engine on automatically. It will finish starting in a moment."
        case .enabled:
            return "Transfers keep running in the background. The engine starts with Flow and stays available."
        case .requiresApproval:
            return "Allow Flow Download Manager in Login Items (once). After that the engine stays on — Flow will not ask again every launch."
        case .notFound:
            return "Flow is starting the transfer engine with a local LaunchAgent fallback."
        case let .unknown(code):
            return "Reported an unrecognized status code (\(code)). Use Repair if downloads stall."
        }
    }

    /// Whether the UI should surface a "Open System Settings" affordance.
    public var needsSystemSettingsApproval: Bool {
        self == .requiresApproval
    }

    /// Whether the engine is registered and allowed — not a live process probe.
    public var isOperational: Bool {
        self == .enabled
    }

    /// Compact subtitle under the sidebar badge.
    public var badgeSubtitle: String {
        switch self {
        case .enabled: return "always on"
        case .notRegistered: return "starting…"
        case .requiresApproval: return "needs approval once"
        case .notFound: return "starting…"
        case .unknown: return "unknown"
        }
    }
}
