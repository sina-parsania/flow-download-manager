// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Harmless health/status/version snapshot returned by ``EngineControlProtocol/healthStatus(requestID:reply:)``.
///
/// Phase 0 carries no download state: the agent reports liveness, its build,
/// database schema version and uptime only. Immutable value holder;
/// `@unchecked Sendable` is justified by all-`let` `Sendable` storage and covered
/// by `HandshakeCodingTests`.
@objc(DMEngineHealthSnapshot)
public final class EngineHealthSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let engineBuild: String
    public let databaseVersion: Int
    public let databaseOpen: Bool
    public let uptimeSeconds: Double

    public init(
        requestID: String,
        engineBuild: String,
        databaseVersion: Int,
        databaseOpen: Bool,
        uptimeSeconds: Double
    ) {
        self.requestID = requestID
        self.engineBuild = engineBuild
        self.databaseVersion = databaseVersion
        self.databaseOpen = databaseOpen
        self.uptimeSeconds = uptimeSeconds
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let build = coder.decodeObject(of: NSString.self, forKey: "engineBuild")
        guard let requestID, let build,
              requestID.length <= EngineXPC.maxPayloadStringLength,
              build.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.requestID = requestID as String
        engineBuild = build as String
        databaseVersion = coder.decodeInteger(forKey: "databaseVersion")
        databaseOpen = coder.decodeBool(forKey: "databaseOpen")
        uptimeSeconds = coder.decodeDouble(forKey: "uptimeSeconds")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(engineBuild as NSString, forKey: "engineBuild")
        coder.encode(databaseVersion, forKey: "databaseVersion")
        coder.encode(databaseOpen, forKey: "databaseOpen")
        coder.encode(uptimeSeconds, forKey: "uptimeSeconds")
    }
}
