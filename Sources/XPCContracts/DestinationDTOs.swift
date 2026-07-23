// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@objc(DMDefaultDestinationSnapshot)
public final class DefaultDestinationSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let pathDisplay: String
    public let folderName: String
    public let isDefaultDownloads: Bool

    public init(pathDisplay: String, folderName: String, isDefaultDownloads: Bool) {
        self.pathDisplay = pathDisplay
        self.folderName = folderName
        self.isDefaultDownloads = isDefaultDownloads
    }

    public required init?(coder: NSCoder) {
        let pathDisplay = coder.decodeObject(of: NSString.self, forKey: "pathDisplay")
        let folderName = coder.decodeObject(of: NSString.self, forKey: "folderName")
        guard let pathDisplay, let folderName,
              pathDisplay.length > 0, pathDisplay.length <= EngineXPC.maxPayloadStringLength,
              folderName.length > 0, folderName.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.pathDisplay = pathDisplay as String
        self.folderName = folderName as String
        isDefaultDownloads = coder.decodeBool(forKey: "isDefaultDownloads")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(pathDisplay as NSString, forKey: "pathDisplay")
        coder.encode(folderName as NSString, forKey: "folderName")
        coder.encode(isDefaultDownloads, forKey: "isDefaultDownloads")
    }
}

@objc(DMGetDefaultDestinationResponse)
public final class GetDefaultDestinationResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let destination: DefaultDestinationSnapshot

    public init(requestID: String, destination: DefaultDestinationSnapshot) {
        self.requestID = requestID
        self.destination = destination
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let destination = coder.decodeObject(
            of: DefaultDestinationSnapshot.self,
            forKey: "destination"
        )
        guard let requestID, let destination,
              UUID(uuidString: requestID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.destination = destination
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(destination, forKey: "destination")
    }
}

@objc(DMSetDefaultDestinationRequest)
public final class SetDefaultDestinationRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    /// When nil, agent resets to ~/Downloads/DownloadManager.
    public let bookmarkData: Data?
    public let displayName: String?
    /// Absolute path chosen in the app (agent may not resolve app security-scoped bookmarks).
    public let pathDisplay: String?

    public init(
        requestID: String,
        bookmarkData: Data?,
        displayName: String?,
        pathDisplay: String? = nil
    ) {
        self.requestID = requestID
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.pathDisplay = pathDisplay
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let bookmarkData = coder.decodeObject(of: NSData.self, forKey: "bookmarkData")
        let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName")
        let pathDisplay = coder.decodeObject(of: NSString.self, forKey: "pathDisplay")
        guard let requestID, UUID(uuidString: requestID as String) != nil else { return nil }
        if let bookmarkData, bookmarkData.length == 0
            || bookmarkData.length > EngineXPC.maxBookmarkDataLength {
            return nil
        }
        if let displayName, displayName.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        if let pathDisplay, pathDisplay.length == 0
            || pathDisplay.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        self.requestID = requestID as String
        self.bookmarkData = bookmarkData.map { $0 as Data }
        self.displayName = displayName.map { $0 as String }
        self.pathDisplay = pathDisplay.map { $0 as String }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        if let bookmarkData {
            coder.encode(bookmarkData as NSData, forKey: "bookmarkData")
        }
        if let displayName {
            coder.encode(displayName as NSString, forKey: "displayName")
        }
        if let pathDisplay {
            coder.encode(pathDisplay as NSString, forKey: "pathDisplay")
        }
    }
}

@objc(DMSetDefaultDestinationResponse)
public final class SetDefaultDestinationResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let destination: DefaultDestinationSnapshot

    public init(requestID: String, destination: DefaultDestinationSnapshot) {
        self.requestID = requestID
        self.destination = destination
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let destination = coder.decodeObject(
            of: DefaultDestinationSnapshot.self,
            forKey: "destination"
        )
        guard let requestID, let destination,
              UUID(uuidString: requestID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.destination = destination
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(destination, forKey: "destination")
    }
}

public extension EngineXPC {
    /// Security-scoped folder bookmarks are small; hard-cap to bound XPC DoS.
    static let maxBookmarkDataLength = 64 * 1024
}
