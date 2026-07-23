// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@objc(DMGetBoolSettingRequest)
public final class GetBoolSettingRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let key: String

    public init(requestID: String, key: String) {
        self.requestID = requestID
        self.key = key
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let key = coder.decodeObject(of: NSString.self, forKey: "key")
        guard let requestID, let key,
              UUID(uuidString: requestID as String) != nil,
              key.length > 0, key.length <= 128
        else { return nil }
        self.requestID = requestID as String
        self.key = key as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(key as NSString, forKey: "key")
    }
}

@objc(DMGetBoolSettingResponse)
public final class GetBoolSettingResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let key: String
    public let value: Bool

    public init(requestID: String, key: String, value: Bool) {
        self.requestID = requestID
        self.key = key
        self.value = value
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let key = coder.decodeObject(of: NSString.self, forKey: "key")
        guard let requestID, let key,
              UUID(uuidString: requestID as String) != nil,
              key.length > 0, key.length <= 128
        else { return nil }
        self.requestID = requestID as String
        self.key = key as String
        value = coder.decodeBool(forKey: "value")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(key as NSString, forKey: "key")
        coder.encode(value, forKey: "value")
    }
}

@objc(DMSetBoolSettingRequest)
public final class SetBoolSettingRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let key: String
    public let value: Bool

    public init(requestID: String, key: String, value: Bool) {
        self.requestID = requestID
        self.key = key
        self.value = value
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let key = coder.decodeObject(of: NSString.self, forKey: "key")
        guard let requestID, let key,
              UUID(uuidString: requestID as String) != nil,
              key.length > 0, key.length <= 128
        else { return nil }
        self.requestID = requestID as String
        self.key = key as String
        value = coder.decodeBool(forKey: "value")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(key as NSString, forKey: "key")
        coder.encode(value, forKey: "value")
    }
}

@objc(DMSetBoolSettingResponse)
public final class SetBoolSettingResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let key: String
    public let value: Bool

    public init(requestID: String, key: String, value: Bool) {
        self.requestID = requestID
        self.key = key
        self.value = value
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let key = coder.decodeObject(of: NSString.self, forKey: "key")
        guard let requestID, let key,
              UUID(uuidString: requestID as String) != nil,
              key.length > 0, key.length <= 128
        else { return nil }
        self.requestID = requestID as String
        self.key = key as String
        value = coder.decodeBool(forKey: "value")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(key as NSString, forKey: "key")
        coder.encode(value, forKey: "value")
    }
}
