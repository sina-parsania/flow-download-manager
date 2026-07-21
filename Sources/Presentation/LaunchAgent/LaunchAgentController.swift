// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ServiceManagement
import SharedObservability

/// Registration/status control for the background engine LaunchAgent. The protocol
/// is a seam so the UI model and its tests do not depend on the real
/// `SMAppService` (which requires an installed, user-approved bundle).
public protocol LaunchAgentManaging: Sendable {
    func currentStatus() -> LaunchAgentStatus
    func register() throws
    func unregister() throws
}

/// Production implementation over `SMAppService.agent(plistName:)`.
public struct SMAppServiceLaunchAgent: LaunchAgentManaging {
    public let plistName: String

    /// - Parameter plistName: filename under `Contents/Library/LaunchAgents/`.
    public init(plistName: String) {
        self.plistName = plistName
    }

    private var service: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    public func currentStatus() -> LaunchAgentStatus {
        LaunchAgentStatus(service.status)
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() throws {
        try service.unregister()
    }
}

/// Observable UI model for the background engine. Handles register/unregister via
/// user action and maps failures to a redacted, actionable message.
@MainActor
public final class LaunchAgentModel: ObservableObject {
    @Published public private(set) var status: LaunchAgentStatus
    @Published public private(set) var lastErrorMessage: String?

    private let manager: any LaunchAgentManaging

    public init(manager: any LaunchAgentManaging) {
        self.manager = manager
        status = manager.currentStatus()
    }

    public func refresh() {
        status = manager.currentStatus()
    }

    public func register() {
        do {
            try manager.register()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Couldn’t register the background engine (\(EngineLog.redacted(error)))."
            EngineLog.app.error("launch agent register failed: \(EngineLog.redacted(error), privacy: .public)")
        }
        refresh()
    }

    public func unregister() {
        do {
            try manager.unregister()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Couldn’t unregister the background engine (\(EngineLog.redacted(error)))."
            EngineLog.app.error("launch agent unregister failed: \(EngineLog.redacted(error), privacy: .public)")
        }
        refresh()
    }

    /// Opens the Login Items pane of System Settings when approval is required.
    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
