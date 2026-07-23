// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public extension EngineXPC {
    /// Maximum URLs accepted in one enqueueBatch call (FR-ING-007).
    static let maxBatchURLCount = 50000
    /// Maximum length of one URL string in a batch payload.
    static let maxURLLength = 16384
}

/// One URL selected for enqueue after client-side review.
@objc(DMBatchURLItem)
public final class BatchURLItem: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let url: String
    public let categoryStableKey: String

    public init(url: String, categoryStableKey: String) {
        self.url = url
        self.categoryStableKey = categoryStableKey
    }

    public required init?(coder: NSCoder) {
        let url = coder.decodeObject(of: NSString.self, forKey: "url")
        let category = coder.decodeObject(of: NSString.self, forKey: "categoryStableKey")
        guard let url, let category,
              url.length > 0, url.length <= EngineXPC.maxURLLength,
              category.length > 0, category.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.url = url as String
        categoryStableKey = category as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(url as NSString, forKey: "url")
        coder.encode(categoryStableKey as NSString, forKey: "categoryStableKey")
    }
}

/// Enqueue a reviewed batch atomically (FR-ING-010 acknowledgement path).
@objc(DMEnqueueBatchRequest)
public final class EnqueueBatchRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let source: String
    public let displayName: String?
    public let items: [BatchURLItem]

    public init(requestID: String, source: String, displayName: String?, items: [BatchURLItem]) {
        self.requestID = requestID
        self.source = source
        self.displayName = displayName
        self.items = items
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let source = coder.decodeObject(of: NSString.self, forKey: "source")
        let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName")
        let items = coder.decodeArrayOfObjects(ofClass: BatchURLItem.self, forKey: "items")
        guard let requestID, let source, let items,
              UUID(uuidString: requestID as String) != nil,
              source.length > 0, source.length <= EngineXPC.maxPayloadStringLength,
              items.count > 0, items.count <= EngineXPC.maxBatchURLCount
        else { return nil }
        if let displayName, displayName.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        self.requestID = requestID as String
        self.source = source as String
        self.displayName = displayName.map { $0 as String }
        self.items = items
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(source as NSString, forKey: "source")
        if let displayName {
            coder.encode(displayName as NSString, forKey: "displayName")
        }
        coder.encode(items as NSArray, forKey: "items")
    }
}

@objc(DMEnqueueBatchResponse)
public final class EnqueueBatchResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let batchID: String
    public let jobIDs: [String]
    public let acceptedCount: Int

    public init(requestID: String, batchID: String, jobIDs: [String], acceptedCount: Int) {
        self.requestID = requestID
        self.batchID = batchID
        self.jobIDs = jobIDs
        self.acceptedCount = acceptedCount
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let batchID = coder.decodeObject(of: NSString.self, forKey: "batchID")
        let jobIDs = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "jobIDs")
        guard let requestID, let batchID, let jobIDs,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: batchID as String) != nil,
              jobIDs.count <= EngineXPC.maxBatchURLCount
        else { return nil }
        self.requestID = requestID as String
        self.batchID = batchID as String
        self.jobIDs = jobIDs.map { $0 as String }
        acceptedCount = coder.decodeInteger(forKey: "acceptedCount")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(batchID as NSString, forKey: "batchID")
        coder.encode(jobIDs as NSArray, forKey: "jobIDs")
        coder.encode(acceptedCount, forKey: "acceptedCount")
    }
}

/// Immutable job snapshot for the library table (XPC read model).
@objc(DMJobSnapshot)
public final class JobSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let id: String
    public let name: String
    public let sourceHost: String
    public let state: String
    public let progressFraction: Double
    public let hasProgress: Bool
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let hasTotalBytes: Bool
    public let speedBytesPerSecond: Int64
    public let categoryKey: String
    public let projectName: String?
    public let tagNames: [String]

    public init(
        id: String,
        name: String,
        sourceHost: String,
        state: String,
        progressFraction: Double?,
        bytesTransferred: Int64,
        totalBytes: Int64?,
        speedBytesPerSecond: Int64,
        categoryKey: String,
        projectName: String? = nil,
        tagNames: [String] = []
    ) {
        self.id = id
        self.name = name
        self.sourceHost = sourceHost
        self.state = state
        self.progressFraction = progressFraction ?? 0
        hasProgress = progressFraction != nil
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes ?? 0
        hasTotalBytes = totalBytes != nil
        self.speedBytesPerSecond = speedBytesPerSecond
        self.categoryKey = categoryKey
        self.projectName = projectName
        self.tagNames = tagNames
    }

    public required init?(coder: NSCoder) {
        let id = coder.decodeObject(of: NSString.self, forKey: "id")
        let name = coder.decodeObject(of: NSString.self, forKey: "name")
        let sourceHost = coder.decodeObject(of: NSString.self, forKey: "sourceHost")
        let state = coder.decodeObject(of: NSString.self, forKey: "state")
        let categoryKey = coder.decodeObject(of: NSString.self, forKey: "categoryKey")
        let projectName = coder.decodeObject(of: NSString.self, forKey: "projectName")
        let tagNames = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "tagNames") ?? []
        guard let id, let name, let sourceHost, let state, let categoryKey,
              UUID(uuidString: id as String) != nil,
              name.length <= EngineXPC.maxPayloadStringLength,
              sourceHost.length <= EngineXPC.maxPayloadStringLength,
              state.length <= 64,
              categoryKey.length <= 64,
              tagNames.count <= EngineXPC.maxCollectionCount
        else { return nil }
        if let projectName, projectName.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        self.id = id as String
        self.name = name as String
        self.sourceHost = sourceHost as String
        self.state = state as String
        self.categoryKey = categoryKey as String
        self.projectName = projectName.map { $0 as String }
        self.tagNames = tagNames.map { $0 as String }
        progressFraction = coder.decodeDouble(forKey: "progressFraction")
        hasProgress = coder.decodeBool(forKey: "hasProgress")
        bytesTransferred = coder.decodeInt64(forKey: "bytesTransferred")
        totalBytes = coder.decodeInt64(forKey: "totalBytes")
        hasTotalBytes = coder.decodeBool(forKey: "hasTotalBytes")
        speedBytesPerSecond = coder.decodeInt64(forKey: "speedBytesPerSecond")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(name as NSString, forKey: "name")
        coder.encode(sourceHost as NSString, forKey: "sourceHost")
        coder.encode(state as NSString, forKey: "state")
        coder.encode(progressFraction, forKey: "progressFraction")
        coder.encode(hasProgress, forKey: "hasProgress")
        coder.encode(bytesTransferred, forKey: "bytesTransferred")
        coder.encode(totalBytes, forKey: "totalBytes")
        coder.encode(hasTotalBytes, forKey: "hasTotalBytes")
        coder.encode(speedBytesPerSecond, forKey: "speedBytesPerSecond")
        coder.encode(categoryKey as NSString, forKey: "categoryKey")
        if let projectName {
            coder.encode(projectName as NSString, forKey: "projectName")
        }
        coder.encode(tagNames as NSArray, forKey: "tagNames")
    }
}

@objc(DMJobListSnapshot)
public final class JobListSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let sequence: Int64
    public let jobs: [JobSnapshot]

    public init(requestID: String, sequence: Int64, jobs: [JobSnapshot]) {
        self.requestID = requestID
        self.sequence = sequence
        self.jobs = jobs
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobs = coder.decodeArrayOfObjects(ofClass: JobSnapshot.self, forKey: "jobs")
        guard let requestID, let jobs,
              UUID(uuidString: requestID as String) != nil,
              jobs.count <= EngineXPC.maxBatchURLCount
        else { return nil }
        self.requestID = requestID as String
        sequence = coder.decodeInt64(forKey: "sequence")
        self.jobs = jobs
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(sequence, forKey: "sequence")
        coder.encode(jobs as NSArray, forKey: "jobs")
    }
}

@objc(DMJobCommand)
public enum JobCommandKind: Int, Sendable {
    case pause = 1
    case resume = 2
    case cancel = 3
    case retry = 4
}

@objc(DMJobCommandRequest)
public final class JobCommandRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String
    public let command: JobCommandKind
    public let expectedRevision: Int

    public init(requestID: String, jobID: String, command: JobCommandKind, expectedRevision: Int) {
        self.requestID = requestID
        self.jobID = jobID
        self.command = command
        self.expectedRevision = expectedRevision
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        let command = JobCommandKind(rawValue: coder.decodeInteger(forKey: "command"))
        guard let requestID, let jobID, let command,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
        self.command = command
        expectedRevision = coder.decodeInteger(forKey: "expectedRevision")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
        coder.encode(command.rawValue, forKey: "command")
        coder.encode(expectedRevision, forKey: "expectedRevision")
    }
}

@objc(DMJobCommandResponse)
public final class JobCommandResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String
    public let state: String
    public let revision: Int

    public init(requestID: String, jobID: String, state: String, revision: Int) {
        self.requestID = requestID
        self.jobID = jobID
        self.state = state
        self.revision = revision
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        let state = coder.decodeObject(of: NSString.self, forKey: "state")
        guard let requestID, let jobID, let state,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
        self.state = state as String
        revision = coder.decodeInteger(forKey: "revision")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
        coder.encode(state as NSString, forKey: "state")
        coder.encode(revision, forKey: "revision")
    }
}
