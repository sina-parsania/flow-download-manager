// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

// GRDB record types for the foundational tables. Column names match the v1 schema
// (SchemaMigrator). States/reasons are stored as their stable string tokens; the
// mapping to Domain enums lives in the Application layer, keeping Domain free of
// GRDB and GRDB free of Domain business rules.

public struct BatchRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "batches"
    public var id: String
    public var createdAt: Date
    public var source: String
    public var originalItemCount: Int
    public var displayName: String?

    public init(id: String, createdAt: Date, source: String, originalItemCount: Int, displayName: String?) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.originalItemCount = originalItemCount
        self.displayName = displayName
    }
}

public struct ResourceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "resources"
    public var id: String
    public var originalURL: String
    public var canonicalURL: String
    public var finalURL: String?
    public var protocolKind: String
    public var filenameEvidence: String?
    public var mimeEvidence: String?
    public var expectedSize: Int64?
    public var strongETag: String?
    public var lastModified: Date?
    public var checksum: String?
    public var identityRevision: Int

    public init(
        id: String, originalURL: String, canonicalURL: String, finalURL: String?,
        protocolKind: String, filenameEvidence: String?, mimeEvidence: String?,
        expectedSize: Int64?, strongETag: String?, lastModified: Date?, checksum: String?,
        identityRevision: Int
    ) {
        self.id = id
        self.originalURL = originalURL
        self.canonicalURL = canonicalURL
        self.finalURL = finalURL
        self.protocolKind = protocolKind
        self.filenameEvidence = filenameEvidence
        self.mimeEvidence = mimeEvidence
        self.expectedSize = expectedSize
        self.strongETag = strongETag
        self.lastModified = lastModified
        self.checksum = checksum
        self.identityRevision = identityRevision
    }
}

public struct CategoryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "categories"
    public var id: String
    public var stableKey: String
    public var displayNameKey: String
    public var systemSymbol: String
    public var destinationProfileID: String?

    public init(
        id: String,
        stableKey: String,
        displayNameKey: String,
        systemSymbol: String,
        destinationProfileID: String?
    ) {
        self.id = id
        self.stableKey = stableKey
        self.displayNameKey = displayNameKey
        self.systemSymbol = systemSymbol
        self.destinationProfileID = destinationProfileID
    }
}

public struct DestinationProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "destination_profiles"
    public var id: String
    public var name: String
    public var bookmarkData: Data
    public var volumeIdentity: String?
    public var conflictPolicy: String

    public init(id: String, name: String, bookmarkData: Data, volumeIdentity: String?, conflictPolicy: String) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.volumeIdentity = volumeIdentity
        self.conflictPolicy = conflictPolicy
    }
}

public struct JobRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "jobs"
    public var id: String
    public var batchID: String?
    public var resourceID: String
    public var state: String
    public var priority: Int
    public var queuePosition: Int
    public var categoryID: String
    public var projectID: String?
    public var destinationProfileID: String
    public var scheduleID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int
    public var terminalReason: String?
    public var credentialProfileID: String?
    public var proxyProfileID: String?
    public var cookieProfileID: String?
    public var customHeadersJSON: String?

    public init(
        id: String, batchID: String?, resourceID: String, state: String, priority: Int,
        queuePosition: Int, categoryID: String, projectID: String?, destinationProfileID: String,
        scheduleID: String?, createdAt: Date, updatedAt: Date, revision: Int, terminalReason: String?,
        credentialProfileID: String? = nil, proxyProfileID: String? = nil,
        cookieProfileID: String? = nil, customHeadersJSON: String? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.resourceID = resourceID
        self.state = state
        self.priority = priority
        self.queuePosition = queuePosition
        self.categoryID = categoryID
        self.projectID = projectID
        self.destinationProfileID = destinationProfileID
        self.scheduleID = scheduleID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.terminalReason = terminalReason
        self.credentialProfileID = credentialProfileID
        self.proxyProfileID = proxyProfileID
        self.cookieProfileID = cookieProfileID
        self.customHeadersJSON = customHeadersJSON
    }
}

public struct CookieProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "cookie_profiles"
    public var id: String
    public var displayName: String
    /// Relative path under agent Application Support (e.g. `cookies/<id>.jar`).
    /// Cookie values never enter SQLite.
    public var storageRelativePath: String

    public init(id: String, displayName: String, storageRelativePath: String) {
        self.id = id
        self.displayName = displayName
        self.storageRelativePath = storageRelativePath
    }
}

public struct BandwidthPolicyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "bandwidth_policies"
    public var id: String
    public var name: String
    public var windowsJSON: String
    public var maxBytesPerSecond: Int64

    public init(id: String, name: String, windowsJSON: String, maxBytesPerSecond: Int64) {
        self.id = id
        self.name = name
        self.windowsJSON = windowsJSON
        self.maxBytesPerSecond = maxBytesPerSecond
    }
}

public struct HostObservationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "host_observations"
    public var host: String
    public var observation: String
    public var expiresAt: Date

    public init(host: String, observation: String, expiresAt: Date) {
        self.host = host
        self.observation = observation
        self.expiresAt = expiresAt
    }
}

public struct EventRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "events"
    public var sequence: Int64?
    public var jobID: String?
    public var occurredAt: Date
    public var type: String
    public var sanitizedPayload: String?

    public init(
        sequence: Int64? = nil,
        jobID: String?,
        occurredAt: Date,
        type: String,
        sanitizedPayload: String?
    ) {
        self.sequence = sequence
        self.jobID = jobID
        self.occurredAt = occurredAt
        self.type = type
        self.sanitizedPayload = sanitizedPayload
    }
}

public struct AttemptRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "attempts"
    public var id: String
    public var jobID: String
    public var ordinal: Int
    public var startedAt: Date?
    public var endedAt: Date?
    public var outcome: String?
    public var transferredBytes: Int64
    public var retryCount: Int
    public var dependencyVersions: String?
    public var sanitizedError: String?

    public init(
        id: String, jobID: String, ordinal: Int, startedAt: Date?, endedAt: Date?,
        outcome: String?, transferredBytes: Int64, retryCount: Int,
        dependencyVersions: String?, sanitizedError: String?
    ) {
        self.id = id
        self.jobID = jobID
        self.ordinal = ordinal
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.transferredBytes = transferredBytes
        self.retryCount = retryCount
        self.dependencyVersions = dependencyVersions
        self.sanitizedError = sanitizedError
    }
}

public struct SegmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "segments"
    public var id: String
    public var attemptID: String
    public var lowerBound: Int64
    public var upperBoundExclusive: Int64
    public var committedExclusive: Int64
    public var state: String
    public var retryCount: Int
    public var rollingThroughput: Double

    public init(
        id: String, attemptID: String, lowerBound: Int64, upperBoundExclusive: Int64,
        committedExclusive: Int64, state: String, retryCount: Int, rollingThroughput: Double
    ) {
        self.id = id
        self.attemptID = attemptID
        self.lowerBound = lowerBound
        self.upperBoundExclusive = upperBoundExclusive
        self.committedExclusive = committedExclusive
        self.state = state
        self.retryCount = retryCount
        self.rollingThroughput = rollingThroughput
    }
}

public struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "projects"
    public var id: String
    public var name: String
    public var colorRole: String?
    public var defaultDestinationProfileID: String?

    public init(
        id: String,
        name: String,
        colorRole: String?,
        defaultDestinationProfileID: String?
    ) {
        self.id = id
        self.name = name
        self.colorRole = colorRole
        self.defaultDestinationProfileID = defaultDestinationProfileID
    }
}

public struct TagRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "tags"
    public var id: String
    public var name: String
    public var nameFold: String

    public init(id: String, name: String, nameFold: String) {
        self.id = id
        self.name = name
        self.nameFold = nameFold
    }
}

public struct JobTagRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "job_tags"
    public var jobID: String
    public var tagID: String

    public init(jobID: String, tagID: String) {
        self.jobID = jobID
        self.tagID = tagID
    }
}

/// User category classification rule (FR-CAT). Seeded empty; priority ascending = first match wins.
public struct CategoryRuleRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "category_rules"
    public var id: String
    public var priority: Int
    public var enabled: Bool
    public var predicate: String
    public var action: String
    public var createdByUser: Bool
    public var revision: Int

    public init(
        id: String,
        priority: Int,
        enabled: Bool,
        predicate: String,
        action: String,
        createdByUser: Bool,
        revision: Int
    ) {
        self.id = id
        self.priority = priority
        self.enabled = enabled
        self.predicate = predicate
        self.action = action
        self.createdByUser = createdByUser
        self.revision = revision
    }
}
