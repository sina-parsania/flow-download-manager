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

/// Observable UI model for the background engine. Engine is **required**.
///
/// Production Developer ID builds use `SMAppService`. Ad-hoc / DerivedData builds
/// hit launchd `Launch Constraint Violation` (`EX_CONFIG`) — those heal onto the
/// app-scoped XPC service bundled in `Contents/XPCServices` (not launchd).
@MainActor
public final class LaunchAgentModel: ObservableObject {
    public enum RuntimeMode: Equatable, Sendable {
        case smAppService
        case bundledService
    }

    @Published public private(set) var status: LaunchAgentStatus
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var runtimeMode: RuntimeMode = .smAppService
    /// True only after a successful XPC health probe (when a client is attached),
    /// or after a successful registration outcome in unit tests without a client.
    @Published public private(set) var isEngineReady = false

    private let manager: any LaunchAgentManaging
    private let defaults: UserDefaults
    /// Shared app/library XPC client used to verify the engine actually answers.
    private weak var probeClient: EngineClient?

    private static let bundlePathKey = "engine.lastRegisteredBundlePath"
    private static let loginItemsPromptKey = "engine.loginItemsPromptShown"
    /// After SMAppService proves broken on this machine, skip it and use the
    /// bundled XPC service. Key string is persisted — do not rename the value.
    private static let preferBundledServiceKey = "engine.preferDirectChild"
    /// Key written by earlier heal attempts — treated as prefer-bundled-service.
    private static let preferLegacyKey = "engine.preferLegacyLaunchd"

    public init(
        manager: any LaunchAgentManaging,
        defaults: UserDefaults = .standard
    ) {
        self.manager = manager
        self.defaults = defaults
        status = manager.currentStatus()
        isEngineReady = false
    }

    public var isOperational: Bool {
        isEngineReady
    }

    /// Attach the live XPC client so ensure/repair can probe health.
    public func attachEngineClient(_ client: EngineClient) {
        probeClient = client
    }

    public func refresh() {
        status = manager.currentStatus()
    }

    public func register() {
        do {
            try manager.register()
            lastErrorMessage = nil
            runtimeMode = .smAppService
            defaults.set(Bundle.main.bundleURL.path, forKey: Self.bundlePathKey)
        } catch {
            lastErrorMessage =
                "Flow couldn’t turn on the background engine. Click Repair, then restart Flow if it stays off."
            EngineLog.app.error("launch agent register failed: \(EngineLog.redacted(error), privacy: .public)")
        }
        refresh()
    }

    /// Tear down broken launchd/SM state and start the bundled engine service.
    public func repair() async {
        lastErrorMessage = nil
        await healToBundledService(client: probeClient)
    }

    /// Opens the Login Items pane of System Settings when approval is required.
    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Call once on app launch. Registers when useful, probes XPC, and heals to
    /// the bundled engine service when launchd cannot run the ad-hoc binary.
    public func ensureRunning() async {
        if defaults.bool(forKey: Self.preferBundledServiceKey)
            || defaults.bool(forKey: Self.preferLegacyKey) {
            await healToBundledService(client: probeClient)
            return
        }

        await bootstrapRegistration()

        guard let client = probeClient else {
            applyReadyWithoutProbe()
            return
        }

        if await waitForHealthy(client: client, attempts: 3, delayNanoseconds: 300_000_000) {
            markReadyFromProbe()
            return
        }

        EngineLog.app.error("engine XPC unreachable via SMAppService; healing to bundled XPC service")
        await healToBundledService(client: client)
    }

    // MARK: - Private

    private func bootstrapRegistration() async {
        refresh()
        let bundlePath = Bundle.main.bundleURL.path
        let lastPath = defaults.string(forKey: Self.bundlePathKey)

        switch status {
        case .enabled:
            if lastPath != bundlePath {
                EngineLog.app.info("engine bundle path changed; re-registering")
                do {
                    try manager.unregister()
                } catch { /* best-effort */ }
                await LegacyLaunchAgentCleanup.unloadAsync()
                register()
            }

        case .notRegistered:
            register()
            if status == .requiresApproval {
                promptLoginItemsOnce()
            }

        case .requiresApproval:
            register()
            promptLoginItemsOnce()

        case .notFound, .unknown:
            register()
            refresh()
        }
    }

    private func applyReadyWithoutProbe() {
        refresh()
        if runtimeMode == .bundledService {
            isEngineReady = true
            return
        }
        if status == .enabled {
            isEngineReady = true
            runtimeMode = .smAppService
            defaults.set(Bundle.main.bundleURL.path, forKey: Self.bundlePathKey)
            defaults.set(false, forKey: Self.loginItemsPromptKey)
        }
    }

    private func markReadyFromProbe() {
        refresh()
        isEngineReady = true
        if runtimeMode != .bundledService, status == .enabled {
            runtimeMode = .smAppService
        }
        lastErrorMessage = nil
        defaults.set(Bundle.main.bundleURL.path, forKey: Self.bundlePathKey)
        defaults.set(false, forKey: Self.loginItemsPromptKey)
    }

    private func healToBundledService(client: EngineClient?) async {
        isEngineReady = false
        client?.clearDirectEndpoint()

        // Stop SMAppService KeepAlive/EX_CONFIG thrash from owning the Mach name.
        do {
            try manager.unregister()
        } catch {
            EngineLog.app.error(
                "launch agent unregister during heal: \(EngineLog.redacted(error), privacy: .public)"
            )
        }
        refresh()

        if Self.isRunningUnderXCTest {
            runtimeMode = .bundledService
            isEngineReady = client == nil
            lastErrorMessage = nil
            defaults.set(true, forKey: Self.preferBundledServiceKey)
            return
        }

        // Off the main actor — never block UI with launchctl/waitUntilExit.
        await LegacyLaunchAgentCleanup.unloadAsync()

        do {
            try DirectAgentHost.shared.ensureTransport()
            runtimeMode = .bundledService
            defaults.set(true, forKey: Self.preferBundledServiceKey)
            defaults.set(Bundle.main.bundleURL.path, forKey: Self.bundlePathKey)

            guard let client else {
                isEngineReady = true
                lastErrorMessage = nil
                EngineLog.app.info("engine ready via bundled XPC service (no probe)")
                return
            }

            client.useBundledXPCService()
            if await waitForHealthy(client: client, attempts: 8, delayNanoseconds: 250_000_000) {
                isEngineReady = true
                lastErrorMessage = nil
                EngineLog.app.info("engine ready via bundled XPC service")
                return
            }

            isEngineReady = false
            lastErrorMessage =
                "Engine started but isn’t answering yet. Click Repair Connection again."
            EngineLog.app.error("bundled XPC service present but health probe failed")
        } catch {
            isEngineReady = false
            lastErrorMessage =
                "Flow couldn’t start the background engine. Click Repair Connection, or restart Flow."
            EngineLog.app.error(
                "bundled XPC service heal failed: \(EngineLog.redacted(error), privacy: .public)"
            )
        }
    }

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private func waitForHealthy(
        client: EngineClient,
        attempts: Int,
        delayNanoseconds: UInt64
    ) async -> Bool {
        for index in 0 ..< attempts {
            client.resetConnection()
            if await client.ping(timeoutSeconds: 2.0) {
                return true
            }
            if index + 1 < attempts {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        return false
    }

    private func promptLoginItemsOnce() {
        guard !defaults.bool(forKey: Self.loginItemsPromptKey) else { return }
        defaults.set(true, forKey: Self.loginItemsPromptKey)
        openSystemSettingsLoginItems()
    }
}
