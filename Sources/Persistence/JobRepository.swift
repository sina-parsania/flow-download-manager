// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Stable production identifiers for seeded categories and the default destination.
public enum ProductionSeedIDs {
    public static let destinationDownloads = "10000000-0000-7000-8000-0000000000d1"
    public static let categories: [(id: String, key: String, symbol: String)] = [
        ("10000000-0000-7000-8000-0000000000c1", "videos", "film"),
        ("10000000-0000-7000-8000-0000000000c2", "audio", "waveform"),
        ("10000000-0000-7000-8000-0000000000c3", "images", "photo"),
        ("10000000-0000-7000-8000-0000000000c4", "documents", "doc"),
        ("10000000-0000-7000-8000-0000000000c5", "archives", "archivebox"),
        ("10000000-0000-7000-8000-0000000000c6", "applications", "app"),
        ("10000000-0000-7000-8000-0000000000c7", "torrents", "arrow.triangle.2.circlepath"),
        ("10000000-0000-7000-8000-0000000000c8", "other", "questionmark.folder")
    ]
}

public struct TransferJobDetails: Sendable {
    public let jobID: String
    public let revision: Int
    public let state: String
    public let canonicalURL: String
    public let destinationDirectory: URL
    public let suggestedFilename: String
    public let expectedChecksum: String?
    public let credentialProfileID: String?
    public let proxyProfileID: String?
    public let cookieProfileID: String?
    public let customHeadersJSON: String?
}

/// Agent-only persistence helpers for jobs/batches (sole writer).
public enum JobRepository {
    public static func ensureProductionSeed(
        _ db: Database,
        defaultDestinationDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: defaultDestinationDirectory,
            withIntermediateDirectories: true
        )
        let bookmark = try defaultDestinationDirectory.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        if try DestinationProfileRecord.fetchOne(db, key: ProductionSeedIDs.destinationDownloads) == nil {
            try DestinationProfileRecord(
                id: ProductionSeedIDs.destinationDownloads,
                name: "Downloads",
                bookmarkData: bookmark,
                volumeIdentity: nil,
                conflictPolicy: "uniquify"
            ).insert(db)
        } else {
            try db.execute(
                sql: """
                UPDATE destination_profiles
                SET bookmarkData = ?, name = 'Downloads', conflictPolicy = 'uniquify'
                WHERE id = ?
                """,
                arguments: [bookmark, ProductionSeedIDs.destinationDownloads]
            )
        }

        for entry in ProductionSeedIDs.categories {
            if try CategoryRecord.fetchOne(db, key: entry.id) == nil {
                try CategoryRecord(
                    id: entry.id,
                    stableKey: entry.key,
                    displayNameKey: "category.\(entry.key)",
                    systemSymbol: entry.symbol,
                    destinationProfileID: ProductionSeedIDs.destinationDownloads
                ).insert(db)
            }
        }
    }

    public static func ensureProductionSeed(
        database: EngineDatabase,
        defaultDestinationDirectory: URL
    ) throws {
        try database.pool.write { db in
            try ensureProductionSeed(db, defaultDestinationDirectory: defaultDestinationDirectory)
        }
    }

    public static func categoryID(forStableKey key: String, db: Database) throws -> String {
        guard let row = try CategoryRecord
            .filter(Column("stableKey") == key)
            .fetchOne(db)
        else {
            throw JobRepositoryError.unknownCategory(key)
        }
        return row.id
    }

    public static func insertBatch(
        database: EngineDatabase,
        source: String,
        displayName: String?,
        items: [(url: String, categoryStableKey: String)]
    ) throws -> (batchID: String, jobIDs: [String]) {
        try database.pool.write { db in
            let now = Date()
            let batchID = UUID().uuidString.lowercased()
            try BatchRecord(
                id: batchID,
                createdAt: now,
                source: source,
                originalItemCount: items.count,
                displayName: displayName
            ).insert(db)

            var jobIDs: [String] = []
            jobIDs.reserveCapacity(items.count)
            var position = 0
            for item in items {
                let categoryID = try categoryID(forStableKey: item.categoryStableKey, db: db)
                let resourceID = UUID().uuidString.lowercased()
                let jobID = UUID().uuidString.lowercased()
                let protocolKind = URL(string: item.url)?.scheme?.lowercased() ?? "http"
                let filename = URL(string: item.url)?.lastPathComponent
                try ResourceRecord(
                    id: resourceID,
                    originalURL: item.url,
                    canonicalURL: item.url,
                    finalURL: nil,
                    protocolKind: protocolKind,
                    filenameEvidence: filename,
                    mimeEvidence: nil,
                    expectedSize: nil,
                    strongETag: nil,
                    lastModified: nil,
                    checksum: nil,
                    identityRevision: 1
                ).insert(db)
                try JobRecord(
                    id: jobID,
                    batchID: batchID,
                    resourceID: resourceID,
                    state: "queued",
                    priority: 0,
                    queuePosition: position,
                    categoryID: categoryID,
                    projectID: nil,
                    destinationProfileID: ProductionSeedIDs.destinationDownloads,
                    scheduleID: nil,
                    createdAt: now,
                    updatedAt: now,
                    revision: 1,
                    terminalReason: nil
                ).insert(db)
                jobIDs.append(jobID)
                position += 1
            }
            return (batchID, jobIDs)
        }
    }

    public static func fetchJobRows(
        database: EngineDatabase
    ) throws -> [(
        job: JobRecord,
        resource: ResourceRecord,
        category: CategoryRecord,
        projectName: String?,
        tagNames: [String]
    )] {
        try database.pool.read { db in
            let jobs = try JobRecord
                .order(Column("queuePosition").asc, Column("createdAt").asc)
                .fetchAll(db)
            var rows: [(JobRecord, ResourceRecord, CategoryRecord, String?, [String])] = []
            rows.reserveCapacity(jobs.count)
            for job in jobs {
                guard let resource = try ResourceRecord.fetchOne(db, key: job.resourceID),
                      let category = try CategoryRecord.fetchOne(db, key: job.categoryID)
                else {
                    throw JobRepositoryError.jobNotFound(job.id)
                }
                let projectName: String? = if let projectID = job.projectID {
                    try ProjectRecord.fetchOne(db, key: projectID)?.name
                } else {
                    nil
                }
                let tagNames = try String.fetchAll(
                    db,
                    sql: """
                    SELECT t.name FROM tags t
                    INNER JOIN job_tags jt ON jt.tagID = t.id
                    WHERE jt.jobID = ?
                    ORDER BY t.name ASC
                    """,
                    arguments: [job.id]
                )
                rows.append((job, resource, category, projectName, tagNames))
            }
            return rows
        }
    }

    public static func fetchQueuedJobIDs(database: EngineDatabase, limit: Int) throws -> [String] {
        try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT id FROM jobs
                WHERE state = 'queued'
                ORDER BY priority DESC, queuePosition ASC, createdAt ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
        }
    }

    /// Active transfer states that cannot survive an agent crash mid-flight.
    /// On relaunch these are moved back to `queued` so the pump can resume
    /// (FR-TRN recovery).
    public static let interruptedTransferStates: Set<String> = [
        "connecting", "downloading", "verifying", "merging", "postProcessing"
    ]

    /// Requeue jobs left in active transfer states after a crash/relaunch.
    /// Clears `terminalReason`, appends `recovery.requeued`, bumps revision.
    /// Returns the requeued job IDs (stable order by queuePosition, createdAt).
    public static func requeueInterruptedTransfers(database: EngineDatabase) throws -> [String] {
        try database.pool.write { db in
            let states = Array(interruptedTransferStates).sorted()
            let placeholders = states.map { _ in "?" }.joined(separator: ", ")
            let interrupted = try JobRecord.fetchAll(
                db,
                sql: """
                SELECT * FROM jobs
                WHERE state IN (\(placeholders))
                ORDER BY queuePosition ASC, createdAt ASC
                """,
                arguments: StatementArguments(states)
            )
            guard !interrupted.isEmpty else { return [] }

            var requeued: [String] = []
            requeued.reserveCapacity(interrupted.count)
            let now = Date()
            for var job in interrupted {
                let previousState = job.state
                job.state = "queued"
                job.terminalReason = nil
                job.updatedAt = now
                job.revision += 1
                try job.update(db)

                let payload: String = if let data = try? JSONSerialization.data(
                    withJSONObject: [
                        "previousState": previousState,
                        "revision": job.revision
                    ] as [String: Any],
                    options: [.sortedKeys]
                ), let string = String(data: data, encoding: .utf8) {
                    string
                } else {
                    "{\"previousState\":\"\(previousState)\",\"revision\":\(job.revision)}"
                }
                try EventRecord(
                    jobID: job.id,
                    occurredAt: now,
                    type: "recovery.requeued",
                    sanitizedPayload: payload
                ).insert(db)
                requeued.append(job.id)
            }
            return requeued
        }
    }

    public static func updateJobState(
        database: EngineDatabase,
        id: String,
        state: String,
        terminalReason: String?,
        expectedRevision: Int?
    ) throws -> Int {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id) else {
                throw JobRepositoryError.jobNotFound(id)
            }
            if let expectedRevision, job.revision != expectedRevision {
                throw JobRepositoryError.revisionConflict(expected: expectedRevision, actual: job.revision)
            }
            job.state = state
            job.terminalReason = terminalReason
            job.updatedAt = Date()
            job.revision += 1
            try job.update(db)

            let payload = Self.sanitizedStatePayload(
                state: state,
                terminalReason: terminalReason,
                revision: job.revision
            )
            try EventRecord(
                jobID: id,
                occurredAt: job.updatedAt,
                type: "state.changed",
                sanitizedPayload: payload
            ).insert(db)
            return job.revision
        }
    }

    /// Append an event-journal row. Payload must already be sanitized (no secrets,
    /// no URLs with query strings).
    public static func appendEvent(
        database: EngineDatabase,
        jobID: String?,
        type: String,
        sanitizedPayload: String?
    ) throws {
        try database.pool.write { db in
            try EventRecord(
                jobID: jobID,
                occurredAt: Date(),
                type: type,
                sanitizedPayload: sanitizedPayload
            ).insert(db)
        }
    }

    private static func sanitizedStatePayload(
        state: String,
        terminalReason: String?,
        revision: Int
    ) -> String {
        var object: [String: Any] = [
            "state": state,
            "revision": revision
        ]
        if let terminalReason {
            object["terminalReason"] = terminalReason
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{\"state\":\"\(state)\",\"revision\":\(revision)}"
        }
        return string
    }

    public static func loadJobForTransfer(
        database: EngineDatabase,
        id: String
    ) throws -> TransferJobDetails {
        try database.pool.read { db in
            guard let job = try JobRecord.fetchOne(db, key: id),
                  let resource = try ResourceRecord.fetchOne(db, key: job.resourceID),
                  let profile = try DestinationProfileRecord.fetchOne(db, key: job.destinationProfileID)
            else {
                throw JobRepositoryError.jobNotFound(id)
            }
            var isStale = false
            let destination = try URL(
                resolvingBookmarkData: profile.bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let suggested = resource.filenameEvidence
                ?? URL(string: resource.canonicalURL)?.lastPathComponent
                ?? "download.bin"
            return TransferJobDetails(
                jobID: job.id,
                revision: job.revision,
                state: job.state,
                canonicalURL: resource.canonicalURL,
                destinationDirectory: destination,
                suggestedFilename: suggested,
                expectedChecksum: resource.checksum,
                credentialProfileID: job.credentialProfileID,
                proxyProfileID: job.proxyProfileID,
                cookieProfileID: job.cookieProfileID,
                customHeadersJSON: job.customHeadersJSON
            )
        }
    }

    public static func updateResourceIdentity(
        database: EngineDatabase,
        jobID: String,
        finalURL: String?,
        expectedSize: Int64?,
        etag: String?,
        mime: String?
    ) throws {
        try database.pool.write { db in
            guard let job = try JobRecord.fetchOne(db, key: jobID),
                  var resource = try ResourceRecord.fetchOne(db, key: job.resourceID)
            else {
                throw JobRepositoryError.jobNotFound(jobID)
            }
            resource.finalURL = finalURL
            resource.expectedSize = expectedSize
            resource.strongETag = etag
            if let mime { resource.mimeEvidence = mime }
            resource.identityRevision += 1
            try resource.update(db)
        }
    }
}

public enum JobRepositoryError: Error, Equatable, Sendable {
    case unknownCategory(String)
    case jobNotFound(String)
    case revisionConflict(expected: Int, actual: Int)
}
