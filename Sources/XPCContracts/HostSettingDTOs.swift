// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@objc(DMHostSettingSnapshot)
public final class HostSettingSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let host: String
    public let maxConnections: Int?
    public let maxBytesPerSecond: Int64?
    public let userAgent: String?
    public let credentialProfileID: String?

    public init(
        host: String,
        maxConnections: Int?,
        maxBytesPerSecond: Int64?,
        userAgent: String?,
        credentialProfileID: String?
    ) {
        self.host = host
        self.maxConnections = maxConnections
        self.maxBytesPerSecond = maxBytesPerSecond
        self.userAgent = userAgent
        self.credentialProfileID = credentialProfileID
    }

    public required init?(coder: NSCoder) {
        let host = coder.decodeObject(of: NSString.self, forKey: "host")
        guard let host,
              host.length > 0, host.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.host = host as String

        maxConnections = coder.decodeBool(forKey: "hasMaxConnections")
            ? coder.decodeInteger(forKey: "maxConnections")
            : nil
        maxBytesPerSecond = coder.decodeBool(forKey: "hasMaxBytesPerSecond")
            ? coder.decodeInt64(forKey: "maxBytesPerSecond")
            : nil

        let userAgent = coder.decodeObject(of: NSString.self, forKey: "userAgent") as String?
        if let userAgent, userAgent.count > EngineXPC.maxPayloadStringLength { return nil }
        self.userAgent = userAgent

        let credentialProfileID = coder.decodeObject(
            of: NSString.self, forKey: "credentialProfileID"
        ) as String?
        if let credentialProfileID, UUID(uuidString: credentialProfileID) == nil { return nil }
        self.credentialProfileID = credentialProfileID
    }

    public func encode(with coder: NSCoder) {
        coder.encode(host as NSString, forKey: "host")
        coder.encode(maxConnections ?? 0, forKey: "maxConnections")
        coder.encode(maxConnections != nil, forKey: "hasMaxConnections")
        coder.encode(maxBytesPerSecond ?? 0, forKey: "maxBytesPerSecond")
        coder.encode(maxBytesPerSecond != nil, forKey: "hasMaxBytesPerSecond")
        coder.encode(userAgent as NSString?, forKey: "userAgent")
        coder.encode(credentialProfileID as NSString?, forKey: "credentialProfileID")
    }
}

@objc(DMListHostSettingsResponse)
public final class ListHostSettingsResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let settings: [HostSettingSnapshot]

    public init(requestID: String, settings: [HostSettingSnapshot]) {
        self.requestID = requestID
        self.settings = settings
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let settings = coder.decodeArrayOfObjects(ofClass: HostSettingSnapshot.self, forKey: "settings")
        guard let requestID, UUID(uuidString: requestID as String) != nil,
              let settings, settings.count <= EngineXPC.maxCollectionCount
        else { return nil }
        self.requestID = requestID as String
        self.settings = settings
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(settings as NSArray, forKey: "settings")
    }
}

@objc(DMUpsertHostSettingRequest)
public final class UpsertHostSettingRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let host: String
    public let maxConnections: Int?
    public let maxBytesPerSecond: Int64?
    public let userAgent: String?
    public let credentialProfileID: String?
    /// When true, a nil optional clears that field on upsert (replace semantics).
    public let clearUserAgent: Bool
    public let clearCredentialProfileID: Bool

    public init(
        requestID: String,
        host: String,
        maxConnections: Int?,
        maxBytesPerSecond: Int64?,
        userAgent: String?,
        credentialProfileID: String?,
        clearUserAgent: Bool = false,
        clearCredentialProfileID: Bool = false
    ) {
        self.requestID = requestID
        self.host = host
        self.maxConnections = maxConnections
        self.maxBytesPerSecond = maxBytesPerSecond
        self.userAgent = userAgent
        self.credentialProfileID = credentialProfileID
        self.clearUserAgent = clearUserAgent
        self.clearCredentialProfileID = clearCredentialProfileID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let host = coder.decodeObject(of: NSString.self, forKey: "host")
        guard let requestID, UUID(uuidString: requestID as String) != nil,
              let host, host.length > 0, host.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.requestID = requestID as String
        self.host = host as String

        maxConnections = coder.decodeBool(forKey: "hasMaxConnections")
            ? coder.decodeInteger(forKey: "maxConnections")
            : nil
        maxBytesPerSecond = coder.decodeBool(forKey: "hasMaxBytesPerSecond")
            ? coder.decodeInt64(forKey: "maxBytesPerSecond")
            : nil

        let userAgent = coder.decodeObject(of: NSString.self, forKey: "userAgent") as String?
        if let userAgent, userAgent.count > EngineXPC.maxPayloadStringLength { return nil }
        self.userAgent = userAgent

        let credentialProfileID = coder.decodeObject(
            of: NSString.self, forKey: "credentialProfileID"
        ) as String?
        if let credentialProfileID, UUID(uuidString: credentialProfileID) == nil { return nil }
        self.credentialProfileID = credentialProfileID

        clearUserAgent = coder.decodeBool(forKey: "clearUserAgent")
        clearCredentialProfileID = coder.decodeBool(forKey: "clearCredentialProfileID")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(host as NSString, forKey: "host")
        coder.encode(maxConnections ?? 0, forKey: "maxConnections")
        coder.encode(maxConnections != nil, forKey: "hasMaxConnections")
        coder.encode(maxBytesPerSecond ?? 0, forKey: "maxBytesPerSecond")
        coder.encode(maxBytesPerSecond != nil, forKey: "hasMaxBytesPerSecond")
        coder.encode(userAgent as NSString?, forKey: "userAgent")
        coder.encode(credentialProfileID as NSString?, forKey: "credentialProfileID")
        coder.encode(clearUserAgent, forKey: "clearUserAgent")
        coder.encode(clearCredentialProfileID, forKey: "clearCredentialProfileID")
    }
}

@objc(DMUpsertHostSettingResponse)
public final class UpsertHostSettingResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let setting: HostSettingSnapshot

    public init(requestID: String, setting: HostSettingSnapshot) {
        self.requestID = requestID
        self.setting = setting
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let setting = coder.decodeObject(of: HostSettingSnapshot.self, forKey: "setting")
        guard let requestID, UUID(uuidString: requestID as String) != nil, let setting
        else { return nil }
        self.requestID = requestID as String
        self.setting = setting
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(setting, forKey: "setting")
    }
}

@objc(DMDeleteHostSettingRequest)
public final class DeleteHostSettingRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let host: String

    public init(requestID: String, host: String) {
        self.requestID = requestID
        self.host = host
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let host = coder.decodeObject(of: NSString.self, forKey: "host")
        guard let requestID, UUID(uuidString: requestID as String) != nil,
              let host, host.length > 0, host.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.requestID = requestID as String
        self.host = host as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(host as NSString, forKey: "host")
    }
}

@objc(DMDeleteHostSettingResponse)
public final class DeleteHostSettingResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let host: String
    public let deleted: Bool

    public init(requestID: String, host: String, deleted: Bool) {
        self.requestID = requestID
        self.host = host
        self.deleted = deleted
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let host = coder.decodeObject(of: NSString.self, forKey: "host")
        guard let requestID, UUID(uuidString: requestID as String) != nil,
              let host, host.length > 0
        else { return nil }
        self.requestID = requestID as String
        self.host = host as String
        deleted = coder.decodeBool(forKey: "deleted")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(host as NSString, forKey: "host")
        coder.encode(deleted, forKey: "deleted")
    }
}
