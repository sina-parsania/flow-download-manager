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

    public init(
        requestID: String,
        credentials: [CredentialProfileSnapshot],
        proxies: [ProxyProfileSnapshot]
    ) {
        self.requestID = requestID
        self.credentials = credentials
        self.proxies = proxies
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
        guard let requestID, let credentials, let proxies,
              UUID(uuidString: requestID as String) != nil,
              credentials.count <= EngineXPC.maxCollectionCount,
              proxies.count <= EngineXPC.maxCollectionCount
        else { return nil }
        self.requestID = requestID as String
        self.credentials = credentials
        self.proxies = proxies
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(credentials as NSArray, forKey: "credentials")
        coder.encode(proxies as NSArray, forKey: "proxies")
    }
}
