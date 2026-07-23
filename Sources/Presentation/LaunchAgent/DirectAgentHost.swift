// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SharedObservability
import XPCContracts

/// Locates the app-scoped `DownloadEngineAgent.xpc` used when launchd MachServices
/// cannot run the ad-hoc LaunchAgent (`Launch Constraint Violation` / `EX_CONFIG`).
///
/// On macOS 26+, `NSXPCListenerEndpoint` may only be encoded by `NSXPCCoder`, so the
/// old “spawn child + write endpoint file via NSKeyedArchiver” handshake no longer
/// works. The bundled XPC service is demand-launched by `NSXPCConnection(serviceName:)`.
@MainActor
public final class DirectAgentHost {
    public static let shared = DirectAgentHost()

    public enum HostError: Error, Sendable {
        case agentBinaryMissing
        case spawnFailed
        case endpointTimedOut
        case endpointInvalid
    }

    /// Transport selected for ad-hoc / healed engine hosting.
    public enum Transport: Sendable, Equatable {
        case bundledXPCService
    }

    private var activeTransport: Transport?

    private init() {}

    /// Ensure the bundled XPC service is present and mark it as the active transport.
    public func ensureTransport() throws -> Transport {
        if let activeTransport {
            return activeTransport
        }
        guard Self.bundledServiceURL() != nil else {
            throw HostError.agentBinaryMissing
        }
        activeTransport = .bundledXPCService
        EngineLog.app.info("direct engine transport ready (bundled XPC service)")
        return .bundledXPCService
    }

    /// Backward-compatible name used by heal paths that previously awaited an endpoint.
    public func ensureEndpoint() async throws -> Transport {
        try ensureTransport()
    }

    public var currentTransportIfReady: Transport? {
        activeTransport
    }

    /// Clears the active transport preference for this app session.
    public func stop() {
        activeTransport = nil
    }

    public static func bundledServiceURL(bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL
            .appendingPathComponent("Contents/XPCServices", isDirectory: true)
            .appendingPathComponent("\(EngineXPC.bundledXPCServiceName).xpc", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return url
    }
}
