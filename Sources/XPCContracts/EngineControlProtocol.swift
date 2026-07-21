// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Versioned, authenticated control interface exported by the engine agent over
/// XPC (`02-architecture.md` §10, `04-domain-and-data-contracts.md` §9).
///
/// Every method takes an explicit request identifier and replies with a typed
/// DTO or an `NSError` carrying a stable ``XPCErrorCode``. Reply blocks are
/// `@Sendable`: they may be invoked on an arbitrary XPC delivery queue, so
/// callers must not capture non-`Sendable` state.
///
/// The handshake MUST precede any other command; the service rejects commands
/// received before a successful handshake (`fail closed on unknown major version
/// or role`, `06-licensing-security-privacy.md` §4).
@objc(DMEngineControlProtocol)
public protocol EngineControlProtocol {
    /// Negotiate protocol version and exchange build/database metadata.
    /// Rejected with ``XPCErrorCode/unsupportedProtocolVersion`` when the client
    /// major version is unknown.
    func handshake(
        _ hello: ClientHello,
        reply: @escaping @Sendable (ServerHello?, NSError?) -> Void
    )

    /// Harmless health/status probe. Requires a prior successful handshake on the
    /// same connection. `requestID` is a UUID string used for idempotency and
    /// duplicate-detection (`04-domain-and-data-contracts.md` §9).
    func healthStatus(
        requestID: String,
        reply: @escaping @Sendable (EngineHealthSnapshot?, NSError?) -> Void
    )
}

/// Mach service name the agent's `NSXPCListener` binds and the app connects to.
/// Kept equal to the LaunchAgent label so launchd on-demand launch and XPC
/// addressing use one identity. This is an owner-supplied local development value
/// (see `Configuration/BundleIdentifiers.xcconfig`); the constant and the
/// `Contents/Library/LaunchAgents/*.plist` `Label`/`MachServices` keys must stay
/// in sync.
public enum EngineXPC {
    public static let machServiceName = "org.downloadmanager.local.DownloadEngineAgent"

    /// Hard cap on any single decoded XPC payload string/collection to bound
    /// interprocess DoS (`06-licensing-security-privacy.md` §4). Larger transfers
    /// use dedicated chunked/file-handle methods, never one giant message.
    public static let maxPayloadStringLength = 4096
    public static let maxCollectionCount = 4096
}
