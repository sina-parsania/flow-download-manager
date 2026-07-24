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
    }

    /// True once the bundled service has been located this session. There is
    /// only one transport now, so this is a flag rather than an enum.
    public private(set) var isBundledServiceReady = false

    private init() {}

    /// Confirm the bundled XPC service is present and select it for this session.
    public func ensureTransport() throws {
        guard !isBundledServiceReady else { return }
        guard Self.bundledServiceURL() != nil else {
            throw HostError.agentBinaryMissing
        }
        isBundledServiceReady = true
        EngineLog.app.info("engine transport ready (bundled XPC service)")
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
