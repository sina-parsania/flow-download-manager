// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@objc(DMEventSnapshot)
public final class EventSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let sequence: Int64
    public let jobID: String?
    public let occurredAtISO8601: String
    public let type: String
    public let sanitizedPayload: String?

    public init(
        sequence: Int64,
        jobID: String?,
        occurredAtISO8601: String,
        type: String,
        sanitizedPayload: String?
    ) {
        self.sequence = sequence
        self.jobID = jobID
        self.occurredAtISO8601 = occurredAtISO8601
        self.type = type
        self.sanitizedPayload = sanitizedPayload
    }

    public required init?(coder: NSCoder) {
        let sequence = coder.decodeInt64(forKey: "sequence")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        let occurredAtISO8601 = coder.decodeObject(of: NSString.self, forKey: "occurredAtISO8601")
        let type = coder.decodeObject(of: NSString.self, forKey: "type")
        let sanitizedPayload = coder.decodeObject(of: NSString.self, forKey: "sanitizedPayload")
        guard sequence > 0,
              let occurredAtISO8601,
              occurredAtISO8601.length > 0,
              occurredAtISO8601.length <= EngineXPC.maxPayloadStringLength,
              let type,
              type.length > 0,
              type.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        if let jobID {
            guard UUID(uuidString: jobID as String) != nil else { return nil }
        }
        if let sanitizedPayload, sanitizedPayload.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        self.sequence = sequence
        self.jobID = jobID.map { $0 as String }
        self.occurredAtISO8601 = occurredAtISO8601 as String
        self.type = type as String
        self.sanitizedPayload = sanitizedPayload.map { $0 as String }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(sequence, forKey: "sequence")
        if let jobID {
            coder.encode(jobID as NSString, forKey: "jobID")
        }
        coder.encode(occurredAtISO8601 as NSString, forKey: "occurredAtISO8601")
        coder.encode(type as NSString, forKey: "type")
        if let sanitizedPayload {
            coder.encode(sanitizedPayload as NSString, forKey: "sanitizedPayload")
        }
    }
}

@objc(DMListEventsRequest)
public final class ListEventsRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String?
    public let limit: Int

    public init(requestID: String, jobID: String?, limit: Int) {
        self.requestID = requestID
        self.jobID = jobID
        self.limit = limit
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        let limit = coder.decodeInteger(forKey: "limit")
        guard let requestID,
              UUID(uuidString: requestID as String) != nil,
              limit > 0,
              limit <= EngineXPC.maxCollectionCount
        else { return nil }
        if let jobID {
            guard UUID(uuidString: jobID as String) != nil else { return nil }
        }
        self.requestID = requestID as String
        self.jobID = jobID.map { $0 as String }
        self.limit = limit
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        if let jobID {
            coder.encode(jobID as NSString, forKey: "jobID")
        }
        coder.encode(limit, forKey: "limit")
    }
}

@objc(DMListEventsResponse)
public final class ListEventsResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let events: [EventSnapshot]

    public init(requestID: String, events: [EventSnapshot]) {
        self.requestID = requestID
        self.events = events
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let events = coder.decodeArrayOfObjects(ofClass: EventSnapshot.self, forKey: "events")
        guard let requestID, let events,
              UUID(uuidString: requestID as String) != nil,
              events.count <= EngineXPC.maxCollectionCount
        else { return nil }
        self.requestID = requestID as String
        self.events = events
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(events as NSArray, forKey: "events")
    }
}
