// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Non-secret credential profile snapshot for Settings.
@objc(DMCredentialProfileSnapshot)
public final class CredentialProfileSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let id: String
    public let displayName: String
    public let username: String

    public init(id: String, displayName: String, username: String) {
        self.id = id
        self.displayName = displayName
        self.username = username
    }

    public required init?(coder: NSCoder) {
        let id = coder.decodeObject(of: NSString.self, forKey: "id")
        let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName")
        let username = coder.decodeObject(of: NSString.self, forKey: "username")
        guard let id, let displayName, let username,
              UUID(uuidString: id as String) != nil,
              displayName.length > 0, displayName.length <= EngineXPC.maxPayloadStringLength,
              username.length > 0, username.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.id = id as String
        self.displayName = displayName as String
        self.username = username as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(displayName as NSString, forKey: "displayName")
        coder.encode(username as NSString, forKey: "username")
    }
}

/// Non-secret proxy profile snapshot for Settings.
@objc(DMProxyProfileSnapshot)
public final class ProxyProfileSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let id: String
    public let displayName: String
    public let kind: String
    public let host: String
    public let port: Int

    public init(id: String, displayName: String, kind: String, host: String, port: Int) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.host = host
        self.port = port
    }

    public required init?(coder: NSCoder) {
        let id = coder.decodeObject(of: NSString.self, forKey: "id")
        let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName")
        let kind = coder.decodeObject(of: NSString.self, forKey: "kind")
        let host = coder.decodeObject(of: NSString.self, forKey: "host")
        let port = coder.decodeInteger(forKey: "port")
        guard let id, let displayName, let kind, let host,
              UUID(uuidString: id as String) != nil,
              displayName.length > 0, displayName.length <= EngineXPC.maxPayloadStringLength,
              Self.allowedKinds.contains(kind as String),
              host.length > 0, host.length <= EngineXPC.maxPayloadStringLength,
              port >= 1, port <= 65535
        else { return nil }
        self.id = id as String
        self.displayName = displayName as String
        self.kind = kind as String
        self.host = host as String
        self.port = port
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(displayName as NSString, forKey: "displayName")
        coder.encode(kind as NSString, forKey: "kind")
        coder.encode(host as NSString, forKey: "host")
        coder.encode(port, forKey: "port")
    }

    public static let allowedKinds: Set<String> = ["http", "https", "socks5"]
}

/// Cookie jar profile snapshot (path only — never cookie values).
@objc(DMCookieProfileSnapshot)
public final class CookieProfileSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public required init?(coder: NSCoder) {
        let id = coder.decodeObject(of: NSString.self, forKey: "id")
        let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName")
        guard let id, let displayName,
              UUID(uuidString: id as String) != nil,
              displayName.length > 0, displayName.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.id = id as String
        self.displayName = displayName as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(displayName as NSString, forKey: "displayName")
    }
}

/// Global bandwidth policy snapshot for Settings (FR-QUE).
@objc(DMBandwidthPolicySnapshot)
public final class BandwidthPolicySnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let id: String
    public let name: String
    public let windowsJSON: String
    public let maxBytesPerSecond: Int64

    public init(id: String, name: String, windowsJSON: String, maxBytesPerSecond: Int64) {
        self.id = id
        self.name = name
        self.windowsJSON = windowsJSON
        self.maxBytesPerSecond = maxBytesPerSecond
    }

    public required init?(coder: NSCoder) {
        let id = coder.decodeObject(of: NSString.self, forKey: "id")
        let name = coder.decodeObject(of: NSString.self, forKey: "name")
        let windowsJSON = coder.decodeObject(of: NSString.self, forKey: "windowsJSON")
        let maxBytesPerSecond = coder.decodeInt64(forKey: "maxBytesPerSecond")
        guard let id, let name, let windowsJSON,
              UUID(uuidString: id as String) != nil,
              name.length > 0, name.length <= EngineXPC.maxPayloadStringLength,
              windowsJSON.length <= EngineXPC.maxPayloadStringLength,
              maxBytesPerSecond >= 0
        else { return nil }
        self.id = id as String
        self.name = name as String
        self.windowsJSON = windowsJSON as String
        self.maxBytesPerSecond = maxBytesPerSecond
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(name as NSString, forKey: "name")
        coder.encode(windowsJSON as NSString, forKey: "windowsJSON")
        coder.encode(maxBytesPerSecond, forKey: "maxBytesPerSecond")
    }
}

@objc(DMUpsertCredentialProfileRequest)
public final class UpsertCredentialProfileRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let profileID: String
    public let displayName: String
    public let username: String
    /// Password UTF-8 bytes travel only over authenticated XPC; never persisted in SQLite.
    public let passwordUTF8: Data

    public init(
        requestID: String,
        profileID: String,
        displayName: String,
        username: String,
        passwordUTF8: Data
    ) {
        self.requestID = requestID
        self.profileID = profileID
        self.displayName = displayName
        self.username = username
        self.passwordUTF8 = passwordUTF8
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let profileID = coder.decodeObject(of: NSString.self, forKey: "profileID")
        let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName")
        let username = coder.decodeObject(of: NSString.self, forKey: "username")
        let passwordUTF8 = coder.decodeObject(of: NSData.self, forKey: "passwordUTF8")
        guard let requestID, let profileID, let displayName, let username, let passwordUTF8,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: profileID as String) != nil,
              displayName.length > 0, displayName.length <= EngineXPC.maxPayloadStringLength,
              username.length > 0, username.length <= EngineXPC.maxPayloadStringLength,
              passwordUTF8.length > 0, passwordUTF8.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.requestID = requestID as String
        self.profileID = profileID as String
        self.displayName = displayName as String
        self.username = username as String
        self.passwordUTF8 = passwordUTF8 as Data
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(profileID as NSString, forKey: "profileID")
        coder.encode(displayName as NSString, forKey: "displayName")
        coder.encode(username as NSString, forKey: "username")
        coder.encode(passwordUTF8 as NSData, forKey: "passwordUTF8")
    }
}

@objc(DMUpsertCredentialProfileResponse)
public final class UpsertCredentialProfileResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let profileID: String

    public init(requestID: String, profileID: String) {
        self.requestID = requestID
        self.profileID = profileID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let profileID = coder.decodeObject(of: NSString.self, forKey: "profileID")
        guard let requestID, let profileID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: profileID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.profileID = profileID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(profileID as NSString, forKey: "profileID")
    }
}

@objc(DMUpsertProxyProfileRequest)
public final class UpsertProxyProfileRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let profileID: String
    public let displayName: String
    public let kind: String
    public let host: String
    public let port: Int

    public init(
        requestID: String,
        profileID: String,
        displayName: String,
        kind: String,
        host: String,
        port: Int
    ) {
        self.requestID = requestID
        self.profileID = profileID
        self.displayName = displayName
        self.kind = kind
        self.host = host
        self.port = port
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let profileID = coder.decodeObject(of: NSString.self, forKey: "profileID")
        let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName")
        let kind = coder.decodeObject(of: NSString.self, forKey: "kind")
        let host = coder.decodeObject(of: NSString.self, forKey: "host")
        let port = coder.decodeInteger(forKey: "port")
        guard let requestID, let profileID, let displayName, let kind, let host,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: profileID as String) != nil,
              displayName.length > 0, displayName.length <= EngineXPC.maxPayloadStringLength,
              ProxyProfileSnapshot.allowedKinds.contains(kind as String),
              host.length > 0, host.length <= EngineXPC.maxPayloadStringLength,
              port >= 1, port <= 65535
        else { return nil }
        self.requestID = requestID as String
        self.profileID = profileID as String
        self.displayName = displayName as String
        self.kind = kind as String
        self.host = host as String
        self.port = port
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(profileID as NSString, forKey: "profileID")
        coder.encode(displayName as NSString, forKey: "displayName")
        coder.encode(kind as NSString, forKey: "kind")
        coder.encode(host as NSString, forKey: "host")
        coder.encode(port, forKey: "port")
    }
}

@objc(DMUpsertProxyProfileResponse)
public final class UpsertProxyProfileResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let profileID: String

    public init(requestID: String, profileID: String) {
        self.requestID = requestID
        self.profileID = profileID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let profileID = coder.decodeObject(of: NSString.self, forKey: "profileID")
        guard let requestID, let profileID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: profileID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.profileID = profileID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(profileID as NSString, forKey: "profileID")
    }
}

@objc(DMListProfilesResponse)
public final class ListProfilesResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let credentials: [CredentialProfileSnapshot]
    public let proxies: [ProxyProfileSnapshot]
    public let cookies: [CookieProfileSnapshot]

    public init(
        requestID: String,
        credentials: [CredentialProfileSnapshot],
        proxies: [ProxyProfileSnapshot],
        cookies: [CookieProfileSnapshot] = []
    ) {
        self.requestID = requestID
        self.credentials = credentials
        self.proxies = proxies
        self.cookies = cookies
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let credentials = coder.decodeArrayOfObjects(
            ofClass: CredentialProfileSnapshot.self,
            forKey: "credentials"
        )
        let proxies = coder.decodeArrayOfObjects(
            ofClass: ProxyProfileSnapshot.self,
            forKey: "proxies"
        )
        let cookies = coder.decodeArrayOfObjects(
            ofClass: CookieProfileSnapshot.self,
            forKey: "cookies"
        ) ?? []
        guard let requestID, let credentials, let proxies,
              UUID(uuidString: requestID as String) != nil,
              credentials.count <= EngineXPC.maxCollectionCount,
              proxies.count <= EngineXPC.maxCollectionCount,
              cookies.count <= EngineXPC.maxCollectionCount
        else { return nil }
        self.requestID = requestID as String
        self.credentials = credentials
        self.proxies = proxies
        self.cookies = cookies
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(credentials as NSArray, forKey: "credentials")
        coder.encode(proxies as NSArray, forKey: "proxies")
        coder.encode(cookies as NSArray, forKey: "cookies")
    }
}

@objc(DMUpsertCookieProfileRequest)
public final class UpsertCookieProfileRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let profileID: String
    public let displayName: String

    public init(requestID: String, profileID: String, displayName: String) {
        self.requestID = requestID
        self.profileID = profileID
        self.displayName = displayName
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let profileID = coder.decodeObject(of: NSString.self, forKey: "profileID")
        let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName")
        guard let requestID, let profileID, let displayName,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: profileID as String) != nil,
              displayName.length > 0, displayName.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.requestID = requestID as String
        self.profileID = profileID as String
        self.displayName = displayName as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(profileID as NSString, forKey: "profileID")
        coder.encode(displayName as NSString, forKey: "displayName")
    }
}

@objc(DMUpsertCookieProfileResponse)
public final class UpsertCookieProfileResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let profileID: String

    public init(requestID: String, profileID: String) {
        self.requestID = requestID
        self.profileID = profileID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let profileID = coder.decodeObject(of: NSString.self, forKey: "profileID")
        guard let requestID, let profileID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: profileID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.profileID = profileID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(profileID as NSString, forKey: "profileID")
    }
}

@objc(DMUpsertBandwidthPolicyRequest)
public final class UpsertBandwidthPolicyRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let policyID: String
    public let name: String
    public let windowsJSON: String
    public let maxBytesPerSecond: Int64

    public init(
        requestID: String,
        policyID: String,
        name: String,
        windowsJSON: String,
        maxBytesPerSecond: Int64
    ) {
        self.requestID = requestID
        self.policyID = policyID
        self.name = name
        self.windowsJSON = windowsJSON
        self.maxBytesPerSecond = maxBytesPerSecond
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let policyID = coder.decodeObject(of: NSString.self, forKey: "policyID")
        let name = coder.decodeObject(of: NSString.self, forKey: "name")
        let windowsJSON = coder.decodeObject(of: NSString.self, forKey: "windowsJSON")
        let maxBytesPerSecond = coder.decodeInt64(forKey: "maxBytesPerSecond")
        guard let requestID, let policyID, let name, let windowsJSON,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: policyID as String) != nil,
              name.length > 0, name.length <= EngineXPC.maxPayloadStringLength,
              windowsJSON.length <= EngineXPC.maxPayloadStringLength,
              maxBytesPerSecond >= 0
        else { return nil }
        self.requestID = requestID as String
        self.policyID = policyID as String
        self.name = name as String
        self.windowsJSON = windowsJSON as String
        self.maxBytesPerSecond = maxBytesPerSecond
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(policyID as NSString, forKey: "policyID")
        coder.encode(name as NSString, forKey: "name")
        coder.encode(windowsJSON as NSString, forKey: "windowsJSON")
        coder.encode(maxBytesPerSecond, forKey: "maxBytesPerSecond")
    }
}

@objc(DMUpsertBandwidthPolicyResponse)
public final class UpsertBandwidthPolicyResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let policyID: String

    public init(requestID: String, policyID: String) {
        self.requestID = requestID
        self.policyID = policyID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let policyID = coder.decodeObject(of: NSString.self, forKey: "policyID")
        guard let requestID, let policyID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: policyID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.policyID = policyID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(policyID as NSString, forKey: "policyID")
    }
}

@objc(DMGetBandwidthPolicyResponse)
public final class GetBandwidthPolicyResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let policy: BandwidthPolicySnapshot?

    public init(requestID: String, policy: BandwidthPolicySnapshot?) {
        self.requestID = requestID
        self.policy = policy
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let policy = coder.decodeObject(of: BandwidthPolicySnapshot.self, forKey: "policy")
        guard let requestID,
              UUID(uuidString: requestID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.policy = policy
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        if let policy {
            coder.encode(policy, forKey: "policy")
        }
    }
}
