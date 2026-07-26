// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public extension EngineXPC {
    /// Maximum URLs accepted in one enqueueBatch call (FR-ING-007).
    static let maxBatchURLCount = 50000
    /// Maximum length of one URL string in a batch payload.
    static let maxURLLength = 16384
    /// Upper bound on a per-job connection preference. The orchestrator clamps
    /// further to whatever the socket reservation actually granted, so this is a
    /// payload sanity bound and not a promise of that many connections.
    static let maxPreferredConnectionCount = 64
    /// Sanity bound on a per-job rate limit in bytes per second. Far above any
    /// real link; it exists so a hostile payload cannot carry an absurd value.
    static let maxJobBytesPerSecond: Int64 = 1 << 40
}

/// Shape validation for a user-supplied SHA-256 checksum.
///
/// Hashing and comparison live in `IntegrityVerifier`. This only decides whether
/// a string is a well-formed 64-character hex digest and normalizes it to
/// lowercase, so the stored value compares directly against a computed digest.
/// Both the Add sheet and the enqueue decoder go through here, so the client-side
/// message and the boundary check can never disagree.
public enum ChecksumFormat {
    /// Character count of a hex-encoded SHA-256 digest.
    public static let sha256HexLength = 64

    /// Trimmed, lowercased digest when `raw` is exactly 64 ASCII hex characters;
    /// `nil` for anything else, including empty input.
    public static func normalizedSHA256(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed.unicodeScalars)
        guard scalars.count == sha256HexLength else { return nil }
        // Deliberately ASCII-only: `Character.isHexDigit` also accepts full-width
        // and other Unicode digit forms, which would never match a real digest.
        guard scalars.allSatisfy(isASCIIHexDigit) else { return nil }
        return trimmed.lowercased()
    }

    private static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0" ... "9", "a" ... "f", "A" ... "F":
            return true
        default:
            return false
        }
    }
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
    /// Optional batch-level credential profile (applied to every job in the batch).
    public let credentialProfileID: String?
    public let proxyProfileID: String?
    public let cookieProfileID: String?
    public let customHeadersJSON: String?
    public let projectID: String?
    /// When set, jobs are created as `scheduled` with a one-shot schedule.
    public let scheduleStartAtISO8601: String?
    /// Expected SHA-256 of the downloaded bytes, lowercase hex. Verified before
    /// the partial is promoted; a mismatch fails the job with `checksumMismatch`.
    public let expectedChecksumSHA256: String?
    /// Per-job rate limit in bytes per second. Takes precedence over the global
    /// bandwidth policy; `nil` means "use the global setting".
    public let maxBytesPerSecond: Int64?
    /// Per-job connection preference. Still bounded by the socket reservation the
    /// orchestrator obtains for the host; `nil` means "derive from file size".
    public let preferredConnectionCount: Int?

    public init(
        requestID: String,
        source: String,
        displayName: String?,
        items: [BatchURLItem],
        credentialProfileID: String? = nil,
        proxyProfileID: String? = nil,
        cookieProfileID: String? = nil,
        customHeadersJSON: String? = nil,
        projectID: String? = nil,
        scheduleStartAtISO8601: String? = nil,
        expectedChecksumSHA256: String? = nil,
        maxBytesPerSecond: Int64? = nil,
        preferredConnectionCount: Int? = nil
    ) {
        self.requestID = requestID
        self.source = source
        self.displayName = displayName
        self.items = items
        self.credentialProfileID = credentialProfileID
        self.proxyProfileID = proxyProfileID
        self.cookieProfileID = cookieProfileID
        self.customHeadersJSON = customHeadersJSON
        self.projectID = projectID
        self.scheduleStartAtISO8601 = scheduleStartAtISO8601
        self.expectedChecksumSHA256 = expectedChecksumSHA256
        self.maxBytesPerSecond = maxBytesPerSecond
        self.preferredConnectionCount = preferredConnectionCount
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let source = coder.decodeObject(of: NSString.self, forKey: "source")
        let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName")
        let items = coder.decodeArrayOfObjects(ofClass: BatchURLItem.self, forKey: "items")
        let credentialProfileID = coder.decodeObject(of: NSString.self, forKey: "credentialProfileID")
        let proxyProfileID = coder.decodeObject(of: NSString.self, forKey: "proxyProfileID")
        let cookieProfileID = coder.decodeObject(of: NSString.self, forKey: "cookieProfileID")
        let customHeadersJSON = coder.decodeObject(of: NSString.self, forKey: "customHeadersJSON")
        let projectID = coder.decodeObject(of: NSString.self, forKey: "projectID")
        let scheduleStartAtISO8601 = coder.decodeObject(
            of: NSString.self,
            forKey: "scheduleStartAtISO8601"
        )
        let rawChecksum = coder.decodeObject(of: NSString.self, forKey: "expectedChecksumSHA256")
        guard let requestID, let source, let items,
              UUID(uuidString: requestID as String) != nil,
              source.length > 0, source.length <= EngineXPC.maxPayloadStringLength,
              !items.isEmpty, items.count <= EngineXPC.maxBatchURLCount
        else { return nil }
        if let displayName, displayName.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        if let credentialProfileID, UUID(uuidString: credentialProfileID as String) == nil {
            return nil
        }
        if let proxyProfileID, UUID(uuidString: proxyProfileID as String) == nil {
            return nil
        }
        if let cookieProfileID, UUID(uuidString: cookieProfileID as String) == nil {
            return nil
        }
        if let customHeadersJSON, customHeadersJSON.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        if let projectID, UUID(uuidString: projectID as String) == nil {
            return nil
        }
        if let scheduleStartAtISO8601,
           scheduleStartAtISO8601.length == 0
           || scheduleStartAtISO8601.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        // Fail closed: a checksum that cannot be a SHA-256 digest is rejected at
        // the boundary rather than stored and quietly never matched.
        var normalizedChecksum: String?
        if let rawChecksum {
            guard rawChecksum.length <= EngineXPC.maxPayloadStringLength,
                  let normalized = ChecksumFormat.normalizedSHA256(rawChecksum as String)
            else { return nil }
            normalizedChecksum = normalized
        }
        let decodedBytesPerSecond = coder.decodeInt64(forKey: "maxBytesPerSecond")
        let hasBytesPerSecond = coder.containsValue(forKey: "maxBytesPerSecond")
        if hasBytesPerSecond,
           decodedBytesPerSecond <= 0 || decodedBytesPerSecond > EngineXPC.maxJobBytesPerSecond {
            return nil
        }
        let decodedConnectionCount = coder.decodeInteger(forKey: "preferredConnectionCount")
        let hasConnectionCount = coder.containsValue(forKey: "preferredConnectionCount")
        if hasConnectionCount,
           decodedConnectionCount < 1 || decodedConnectionCount > EngineXPC.maxPreferredConnectionCount {
            return nil
        }
        expectedChecksumSHA256 = normalizedChecksum
        maxBytesPerSecond = hasBytesPerSecond ? decodedBytesPerSecond : nil
        preferredConnectionCount = hasConnectionCount ? decodedConnectionCount : nil
        self.requestID = requestID as String
        self.source = source as String
        self.displayName = displayName.map { $0 as String }
        self.items = items
        self.credentialProfileID = credentialProfileID.map { $0 as String }
        self.proxyProfileID = proxyProfileID.map { $0 as String }
        self.cookieProfileID = cookieProfileID.map { $0 as String }
        self.customHeadersJSON = customHeadersJSON.map { $0 as String }
        self.projectID = projectID.map { $0 as String }
        self.scheduleStartAtISO8601 = scheduleStartAtISO8601.map { $0 as String }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(source as NSString, forKey: "source")
        if let displayName {
            coder.encode(displayName as NSString, forKey: "displayName")
        }
        coder.encode(items as NSArray, forKey: "items")
        if let credentialProfileID {
            coder.encode(credentialProfileID as NSString, forKey: "credentialProfileID")
        }
        if let proxyProfileID {
            coder.encode(proxyProfileID as NSString, forKey: "proxyProfileID")
        }
        if let cookieProfileID {
            coder.encode(cookieProfileID as NSString, forKey: "cookieProfileID")
        }
        if let customHeadersJSON {
            coder.encode(customHeadersJSON as NSString, forKey: "customHeadersJSON")
        }
        if let projectID {
            coder.encode(projectID as NSString, forKey: "projectID")
        }
        if let scheduleStartAtISO8601 {
            coder.encode(scheduleStartAtISO8601 as NSString, forKey: "scheduleStartAtISO8601")
        }
        if let expectedChecksumSHA256 {
            coder.encode(expectedChecksumSHA256 as NSString, forKey: "expectedChecksumSHA256")
        }
        // Presence of the key is the optional signal — separate has* Bool flags do not
        // round-trip reliably through NSKeyedArchiver on all macOS/Xcode combos CI uses.
        if let maxBytesPerSecond {
            coder.encode(maxBytesPerSecond, forKey: "maxBytesPerSecond")
        }
        if let preferredConnectionCount {
            coder.encode(preferredConnectionCount, forKey: "preferredConnectionCount")
        }
    }
}

/// Read the per-job transfer settings and integrity outcome for one job.
///
/// Deliberately a separate RPC rather than extra columns on `JobSnapshot`: the
/// library read model is polled at 2 Hz for every row, and these values only
/// matter for the one job the inspector is showing.
@objc(DMGetJobTransferSettingsRequest)
public final class GetJobTransferSettingsRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String

    public init(requestID: String, jobID: String) {
        self.requestID = requestID
        self.jobID = jobID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        guard let requestID, let jobID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
    }
}

@objc(DMGetJobTransferSettingsResponse)
public final class GetJobTransferSettingsResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String
    public let state: String
    public let terminalReason: String?
    /// Expected digest recorded at enqueue, or `nil` when none was supplied.
    public let expectedChecksumSHA256: String?
    /// Per-job rate limit, or `nil` when the job follows the global setting.
    public let maxBytesPerSecond: Int64?
    /// Per-job connection preference, or `nil` when derived from file size.
    public let preferredConnectionCount: Int?
    /// Rate limit the global bandwidth policy imposes right now, or `nil` when
    /// no policy is configured or its calendar window is closed.
    public let globalMaxBytesPerSecond: Int64?

    public init(
        requestID: String,
        jobID: String,
        state: String,
        terminalReason: String?,
        expectedChecksumSHA256: String?,
        maxBytesPerSecond: Int64?,
        preferredConnectionCount: Int?,
        globalMaxBytesPerSecond: Int64?
    ) {
        self.requestID = requestID
        self.jobID = jobID
        self.state = state
        self.terminalReason = terminalReason
        self.expectedChecksumSHA256 = expectedChecksumSHA256
        self.maxBytesPerSecond = maxBytesPerSecond
        self.preferredConnectionCount = preferredConnectionCount
        self.globalMaxBytesPerSecond = globalMaxBytesPerSecond
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        let state = coder.decodeObject(of: NSString.self, forKey: "state")
        let terminalReason = coder.decodeObject(of: NSString.self, forKey: "terminalReason")
        let checksum = coder.decodeObject(of: NSString.self, forKey: "expectedChecksumSHA256")
        guard let requestID, let jobID, let state,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil,
              state.length <= 64
        else { return nil }
        if let terminalReason, terminalReason.length > 64 {
            return nil
        }
        if let checksum, ChecksumFormat.normalizedSHA256(checksum as String) == nil {
            return nil
        }
        self.requestID = requestID as String
        self.jobID = jobID as String
        self.state = state as String
        self.terminalReason = terminalReason.map { $0 as String }
        expectedChecksumSHA256 = checksum.map { $0 as String }
        maxBytesPerSecond = coder.containsValue(forKey: "maxBytesPerSecond")
            ? coder.decodeInt64(forKey: "maxBytesPerSecond")
            : nil
        preferredConnectionCount = coder.containsValue(forKey: "preferredConnectionCount")
            ? coder.decodeInteger(forKey: "preferredConnectionCount")
            : nil
        globalMaxBytesPerSecond = coder.containsValue(forKey: "globalMaxBytesPerSecond")
            ? coder.decodeInt64(forKey: "globalMaxBytesPerSecond")
            : nil
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
        coder.encode(state as NSString, forKey: "state")
        if let terminalReason {
            coder.encode(terminalReason as NSString, forKey: "terminalReason")
        }
        if let expectedChecksumSHA256 {
            coder.encode(expectedChecksumSHA256 as NSString, forKey: "expectedChecksumSHA256")
        }
        if let maxBytesPerSecond {
            coder.encode(maxBytesPerSecond, forKey: "maxBytesPerSecond")
        }
        if let preferredConnectionCount {
            coder.encode(preferredConnectionCount, forKey: "preferredConnectionCount")
        }
        if let globalMaxBytesPerSecond {
            coder.encode(globalMaxBytesPerSecond, forKey: "globalMaxBytesPerSecond")
        }
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
    /// Full download URL (final when known, otherwise canonical).
    public let sourceURL: String
    public let state: String
    public let progressFraction: Double
    public let hasProgress: Bool
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let hasTotalBytes: Bool
    public let speedBytesPerSecond: Int64
    public let categoryKey: String
    public let projectID: String?
    public let projectName: String?
    public let tagIDs: [String]
    public let tagNames: [String]
    public let priority: Int
    /// ISO-8601 UTC; first connecting/downloading time, else nil.
    public let startedAtISO8601: String?
    /// ISO-8601 UTC; first terminal transition, else nil.
    public let completedAtISO8601: String?
    /// Absolute destination directory for this job (bookmark-resolved).
    public let destinationDirectoryPath: String?
    /// Absolute path to the final file or `.partial` when present on disk.
    public let filePath: String?

    public init(
        id: String,
        name: String,
        sourceHost: String,
        sourceURL: String,
        state: String,
        progressFraction: Double?,
        bytesTransferred: Int64,
        totalBytes: Int64?,
        speedBytesPerSecond: Int64,
        categoryKey: String,
        projectID: String? = nil,
        projectName: String? = nil,
        tagIDs: [String] = [],
        tagNames: [String] = [],
        priority: Int = 0,
        startedAtISO8601: String? = nil,
        completedAtISO8601: String? = nil,
        destinationDirectoryPath: String? = nil,
        filePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceHost = sourceHost
        self.sourceURL = sourceURL
        self.state = state
        self.progressFraction = progressFraction ?? 0
        hasProgress = progressFraction != nil
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes ?? 0
        hasTotalBytes = totalBytes != nil
        self.speedBytesPerSecond = speedBytesPerSecond
        self.categoryKey = categoryKey
        self.projectID = projectID
        self.projectName = projectName
        self.tagIDs = tagIDs
        self.tagNames = tagNames
        self.priority = priority
        self.startedAtISO8601 = startedAtISO8601
        self.completedAtISO8601 = completedAtISO8601
        self.destinationDirectoryPath = destinationDirectoryPath
        self.filePath = filePath
    }

    public required init?(coder: NSCoder) {
        let id = coder.decodeObject(of: NSString.self, forKey: "id")
        let name = coder.decodeObject(of: NSString.self, forKey: "name")
        let sourceHost = coder.decodeObject(of: NSString.self, forKey: "sourceHost")
        let sourceURL = coder.decodeObject(of: NSString.self, forKey: "sourceURL")
        let state = coder.decodeObject(of: NSString.self, forKey: "state")
        let categoryKey = coder.decodeObject(of: NSString.self, forKey: "categoryKey")
        let projectID = coder.decodeObject(of: NSString.self, forKey: "projectID")
        let projectName = coder.decodeObject(of: NSString.self, forKey: "projectName")
        let tagIDs = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "tagIDs") ?? []
        let tagNames = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "tagNames") ?? []
        let startedAtISO8601 = coder.decodeObject(of: NSString.self, forKey: "startedAtISO8601")
        let completedAtISO8601 = coder.decodeObject(of: NSString.self, forKey: "completedAtISO8601")
        let destinationDirectoryPath = coder.decodeObject(
            of: NSString.self, forKey: "destinationDirectoryPath"
        )
        let filePath = coder.decodeObject(of: NSString.self, forKey: "filePath")
        guard let id, let name, let sourceHost, let sourceURL, let state, let categoryKey,
              UUID(uuidString: id as String) != nil,
              name.length <= EngineXPC.maxPayloadStringLength,
              sourceHost.length <= EngineXPC.maxPayloadStringLength,
              sourceURL.length > 0, sourceURL.length <= EngineXPC.maxURLLength,
              state.length <= 64,
              categoryKey.length <= 64,
              tagIDs.count <= EngineXPC.maxCollectionCount,
              tagNames.count <= EngineXPC.maxCollectionCount,
              tagIDs.allSatisfy({ UUID(uuidString: $0 as String) != nil })
        else { return nil }
        if let projectID, UUID(uuidString: projectID as String) == nil {
            return nil
        }
        if let projectName, projectName.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        if let startedAtISO8601, startedAtISO8601.length > 64 { return nil }
        if let completedAtISO8601, completedAtISO8601.length > 64 { return nil }
        if let destinationDirectoryPath,
           destinationDirectoryPath.length == 0
           || destinationDirectoryPath.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        if let filePath,
           filePath.length == 0 || filePath.length > EngineXPC.maxPayloadStringLength {
            return nil
        }
        self.id = id as String
        self.name = name as String
        self.sourceHost = sourceHost as String
        self.sourceURL = sourceURL as String
        self.state = state as String
        self.categoryKey = categoryKey as String
        self.projectID = projectID.map { $0 as String }
        self.projectName = projectName.map { $0 as String }
        self.tagIDs = tagIDs.map { $0 as String }
        self.tagNames = tagNames.map { $0 as String }
        self.startedAtISO8601 = startedAtISO8601.map { $0 as String }
        self.completedAtISO8601 = completedAtISO8601.map { $0 as String }
        self.destinationDirectoryPath = destinationDirectoryPath.map { $0 as String }
        self.filePath = filePath.map { $0 as String }
        progressFraction = coder.decodeDouble(forKey: "progressFraction")
        hasProgress = coder.decodeBool(forKey: "hasProgress")
        bytesTransferred = coder.decodeInt64(forKey: "bytesTransferred")
        totalBytes = coder.decodeInt64(forKey: "totalBytes")
        hasTotalBytes = coder.decodeBool(forKey: "hasTotalBytes")
        speedBytesPerSecond = coder.decodeInt64(forKey: "speedBytesPerSecond")
        priority = coder.decodeInteger(forKey: "priority")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(name as NSString, forKey: "name")
        coder.encode(sourceHost as NSString, forKey: "sourceHost")
        coder.encode(sourceURL as NSString, forKey: "sourceURL")
        coder.encode(state as NSString, forKey: "state")
        coder.encode(progressFraction, forKey: "progressFraction")
        coder.encode(hasProgress, forKey: "hasProgress")
        coder.encode(bytesTransferred, forKey: "bytesTransferred")
        coder.encode(totalBytes, forKey: "totalBytes")
        coder.encode(hasTotalBytes, forKey: "hasTotalBytes")
        coder.encode(speedBytesPerSecond, forKey: "speedBytesPerSecond")
        coder.encode(categoryKey as NSString, forKey: "categoryKey")
        if let projectID {
            coder.encode(projectID as NSString, forKey: "projectID")
        }
        if let projectName {
            coder.encode(projectName as NSString, forKey: "projectName")
        }
        coder.encode(tagIDs as NSArray, forKey: "tagIDs")
        coder.encode(tagNames as NSArray, forKey: "tagNames")
        coder.encode(priority, forKey: "priority")
        if let startedAtISO8601 {
            coder.encode(startedAtISO8601 as NSString, forKey: "startedAtISO8601")
        }
        if let completedAtISO8601 {
            coder.encode(completedAtISO8601 as NSString, forKey: "completedAtISO8601")
        }
        if let destinationDirectoryPath {
            coder.encode(destinationDirectoryPath as NSString, forKey: "destinationDirectoryPath")
        }
        if let filePath {
            coder.encode(filePath as NSString, forKey: "filePath")
        }
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
    /// Wipe partial + clear identity size, then requeue (distinct from retry).
    case restart = 5
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

@objc(DMSetJobPriorityRequest)
public final class SetJobPriorityRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String
    public let priority: Int

    public init(requestID: String, jobID: String, priority: Int) {
        self.requestID = requestID
        self.jobID = jobID
        self.priority = priority
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        guard let requestID, let jobID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
        priority = coder.decodeInteger(forKey: "priority")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
        coder.encode(priority, forKey: "priority")
    }
}

@objc(DMSetJobPriorityResponse)
public final class SetJobPriorityResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String
    public let priority: Int
    public let revision: Int

    public init(requestID: String, jobID: String, priority: Int, revision: Int) {
        self.requestID = requestID
        self.jobID = jobID
        self.priority = priority
        self.revision = revision
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        guard let requestID, let jobID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
        priority = coder.decodeInteger(forKey: "priority")
        revision = coder.decodeInteger(forKey: "revision")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
        coder.encode(priority, forKey: "priority")
        coder.encode(revision, forKey: "revision")
    }
}

@objc(DMDeleteJobRequest)
public final class DeleteJobRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String
    /// When `true`, also delete the destination file / `.partial` from disk.
    /// When `false`, only remove the job from the library database.
    public let deleteFiles: Bool

    public init(requestID: String, jobID: String, deleteFiles: Bool = false) {
        self.requestID = requestID
        self.jobID = jobID
        self.deleteFiles = deleteFiles
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        guard let requestID, let jobID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
        deleteFiles = coder.decodeBool(forKey: "deleteFiles")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
        coder.encode(deleteFiles, forKey: "deleteFiles")
    }
}

@objc(DMDeleteJobResponse)
public final class DeleteJobResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String
    public let previousState: String

    public init(requestID: String, jobID: String, previousState: String) {
        self.requestID = requestID
        self.jobID = jobID
        self.previousState = previousState
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        let previousState = coder.decodeObject(of: NSString.self, forKey: "previousState")
        guard let requestID, let jobID, let previousState,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
        self.previousState = previousState as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
        coder.encode(previousState as NSString, forKey: "previousState")
    }
}
