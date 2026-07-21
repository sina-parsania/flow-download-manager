// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Role a connecting client claims. Authorization uses process identity, not this
/// value (`04-domain-and-data-contracts.md` §9); the role only selects the
/// command surface offered.
@objc(DMClientRole)
public enum ClientRole: Int, Sendable {
    case app = 1
    case nativeHost = 2
}

/// `ClientHello { protocolVersion, clientBuild, clientRole, capabilities }`.
///
/// Immutable value holder over a secure-coding boundary. All stored properties
/// are `let` of `Sendable` types, so concurrent reads are data-race-free; hence
/// `@unchecked Sendable`. Covered by `HandshakeCodingTests` which round-trips an
/// instance across a concurrent boundary.
@objc(DMClientHello)
public final class ClientHello: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let protocolVersion: Int
    public let clientBuild: String
    public let clientRole: ClientRole
    public let capabilities: [String]

    public init(protocolVersion: Int, clientBuild: String, clientRole: ClientRole, capabilities: [String]) {
        self.protocolVersion = protocolVersion
        self.clientBuild = clientBuild
        self.clientRole = clientRole
        self.capabilities = capabilities
    }

    public required init?(coder: NSCoder) {
        let build = coder.decodeObject(of: NSString.self, forKey: "clientBuild")
        let caps = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "capabilities")
        guard let build, let caps, let role = ClientRole(rawValue: coder.decodeInteger(forKey: "clientRole")),
              build.length <= EngineXPC.maxPayloadStringLength,
              caps.count <= EngineXPC.maxCollectionCount,
              caps.allSatisfy({ $0.length <= EngineXPC.maxPayloadStringLength })
        else { return nil }
        protocolVersion = coder.decodeInteger(forKey: "protocolVersion")
        clientBuild = build as String
        clientRole = role
        capabilities = caps.map { $0 as String }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(protocolVersion, forKey: "protocolVersion")
        coder.encode(clientBuild as NSString, forKey: "clientBuild")
        coder.encode(clientRole.rawValue, forKey: "clientRole")
        coder.encode(capabilities as NSArray, forKey: "capabilities")
    }
}

/// `ServerHello { acceptedVersion, engineBuild, databaseVersion, capabilities }`.
@objc(DMServerHello)
public final class ServerHello: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let acceptedVersion: Int
    public let engineBuild: String
    public let databaseVersion: Int
    public let capabilities: [String]

    public init(acceptedVersion: Int, engineBuild: String, databaseVersion: Int, capabilities: [String]) {
        self.acceptedVersion = acceptedVersion
        self.engineBuild = engineBuild
        self.databaseVersion = databaseVersion
        self.capabilities = capabilities
    }

    public required init?(coder: NSCoder) {
        let build = coder.decodeObject(of: NSString.self, forKey: "engineBuild")
        let caps = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "capabilities")
        guard let build, let caps,
              build.length <= EngineXPC.maxPayloadStringLength,
              caps.count <= EngineXPC.maxCollectionCount,
              caps.allSatisfy({ $0.length <= EngineXPC.maxPayloadStringLength })
        else { return nil }
        acceptedVersion = coder.decodeInteger(forKey: "acceptedVersion")
        engineBuild = build as String
        databaseVersion = coder.decodeInteger(forKey: "databaseVersion")
        capabilities = caps.map { $0 as String }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(acceptedVersion, forKey: "acceptedVersion")
        coder.encode(engineBuild as NSString, forKey: "engineBuild")
        coder.encode(databaseVersion, forKey: "databaseVersion")
        coder.encode(capabilities as NSArray, forKey: "capabilities")
    }
}
