// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
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
    public let conflictPolicy: String
    public let expectedChecksum: String?
    public let credentialProfileID: String?
    public let proxyProfileID: String?
    public let cookieProfileID: String?
    public let customHeadersJSON: String?
    /// Per-job rate limit in bytes per second; `nil` follows the global policy.
    public let maxBytesPerSecond: Int64?
    /// Per-job connection preference; `nil` derives the count from file size.
    public let preferredConnectionCount: Int?
    /// Folder already stamped for this job, or `nil` if it has not been stamped
    /// yet (first attempt) or the feature was off when it was.
    public let categorySubfolder: String?

    /// Where this job's `.partial`, `.segmap` and final file actually live.
    ///
    /// Every path built for a job must come from here rather than from
    /// ``destinationDirectory``: finalization, the restart wipe and delete-with-files
    /// each rebuild the partial path independently, and one of them using the parent
    /// directory means a promoted file goes to the wrong place or an orphaned
    /// partial is left behind.
    ///
    /// ``destinationDirectory`` remains the right receiver for
    /// `startAccessingSecurityScopedResource` — the scope covers descendants.
    public var writeDirectory: URL {
        guard let categorySubfolder else { return destinationDirectory }
        return destinationDirectory.appendingPathComponent(categorySubfolder, isDirectory: true)
    }
}

/// Inspector-facing view of one job's transfer limits and integrity outcome.
public struct JobTransferSettings: Sendable {
    public let jobID: String
    public let state: String
    public let terminalReason: String?
    public let expectedChecksum: String?
    public let maxBytesPerSecond: Int64?
    public let preferredConnectionCount: Int?
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
        }
        // Existing destination bookmarks are user-owned — never overwrite on launch.

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

    /// Reassign a job to a built-in category by stable key.
    public static func setJobCategory(
        database: EngineDatabase,
        jobID: String,
        categoryStableKey: String
    ) throws {
        let trimmed = categoryStableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JobRepositoryError.unknownCategory(categoryStableKey)
        }
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID) else {
                throw JobRepositoryError.jobNotFound(jobID)
            }
            let categoryID = try categoryID(forStableKey: trimmed, db: db)
            guard job.categoryID != categoryID else { return }
            job.categoryID = categoryID
            job.updatedAt = Date()
            job.revision += 1
            try job.update(db)
        }
    }

    /// Upgrades a job from the `other` category when stronger evidence appears
    /// (MIME / Content-Disposition / final URL). Never overrides a non-`other`
    /// category — that would stomp a user choice.
    @discardableResult
    public static func upgradeCategoryFromOther(
        database: EngineDatabase,
        jobID: String,
        categoryStableKey: String
    ) throws -> Bool {
        let trimmed = categoryStableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "other" else { return false }
        return try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID),
                  let current = try CategoryRecord.fetchOne(db, key: job.categoryID)
            else {
                throw JobRepositoryError.jobNotFound(jobID)
            }
            guard current.stableKey == "other" else { return false }
            let categoryID = try categoryID(forStableKey: trimmed, db: db)
            guard job.categoryID != categoryID else { return false }
            job.categoryID = categoryID
            job.updatedAt = Date()
            job.revision += 1
            try job.update(db)
            return true
        }
    }

    /// Renames the job’s destination / display filename. Refuses while a transfer
    /// is actively writing. Renames on-disk `.partial` / completed files when present.
    @discardableResult
    public static func setJobFilename(
        database: EngineDatabase,
        jobID: String,
        filename: String
    ) throws -> String {
        let sanitized = FilenameSanitizer.sanitize(filename)
        guard !sanitized.isEmpty else {
            throw JobRepositoryError.invalidFilename(filename)
        }

        return try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID),
                  var resource = try ResourceRecord.fetchOne(db, key: job.resourceID),
                  let profile = try DestinationProfileRecord.fetchOne(db, key: job.destinationProfileID)
            else {
                throw JobRepositoryError.jobNotFound(jobID)
            }

            let active: Set<String> = [
                "connecting", "downloading", "verifying", "merging", "postProcessing"
            ]
            if active.contains(job.state) {
                throw JobRepositoryError.renameWhileActive(job.state)
            }

            let previous = FilenameSanitizer.preferredFilename(
                contentDisposition: nil,
                urlString: resource.finalURL ?? resource.canonicalURL,
                existingEvidence: resource.filenameEvidence
            )
            guard previous != sanitized else { return sanitized }

            var isStale = false
            let destination: URL
            do {
                destination = try DestinationBookmark.resolveDirectory(bookmarkData: profile.bookmarkData)
            } catch {
                destination = try URL(
                    resolvingBookmarkData: profile.bookmarkData,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }

            let accessed = destination.startAccessingSecurityScopedResource()
            defer {
                if accessed { destination.stopAccessingSecurityScopedResource() }
            }

            let oldPartial = destination.appendingPathComponent("\(previous).partial")
            let newPartial = destination.appendingPathComponent("\(sanitized).partial")
            let oldFinal = destination.appendingPathComponent(previous)
            let newFinal = destination.appendingPathComponent(sanitized)

            if FileManager.default.fileExists(atPath: oldPartial.path) {
                if FileManager.default.fileExists(atPath: newPartial.path) {
                    throw JobRepositoryError.renameTargetExists(sanitized)
                }
                try FileManager.default.moveItem(at: oldPartial, to: newPartial)
                let oldMap = URL(fileURLWithPath: oldPartial.path + ".segmap")
                let newMap = URL(fileURLWithPath: newPartial.path + ".segmap")
                if FileManager.default.fileExists(atPath: oldMap.path) {
                    try? FileManager.default.removeItem(at: newMap)
                    try FileManager.default.moveItem(at: oldMap, to: newMap)
                }
            }
            if FileManager.default.fileExists(atPath: oldFinal.path) {
                if FileManager.default.fileExists(atPath: newFinal.path) {
                    throw JobRepositoryError.renameTargetExists(sanitized)
                }
                try FileManager.default.moveItem(at: oldFinal, to: newFinal)
            }

            resource.filenameEvidence = sanitized
            resource.identityRevision += 1
            try resource.update(db)
            job.finalFilename = sanitized
            job.destinationPath = destination.path
            job.updatedAt = Date()
            job.revision += 1
            try job.update(db)
            return sanitized
        }
    }

    public static func insertBatch(
        database: EngineDatabase,
        source: String,
        displayName: String?,
        items: [(url: String, categoryStableKey: String)],
        credentialProfileID: String? = nil,
        proxyProfileID: String? = nil,
        cookieProfileID: String? = nil,
        customHeadersJSON: String? = nil,
        projectID: String? = nil,
        scheduleStartAt: Date? = nil,
        expectedChecksumSHA256: String? = nil,
        maxBytesPerSecond: Int64? = nil,
        preferredConnectionCount: Int? = nil
    ) throws -> (batchID: String, jobIDs: [String]) {
        // Stored form is normalized here so the transfer path can treat a present
        // value as usable: blank checksums and non-positive limits become NULL,
        // which is exactly "no override".
        let storedChecksum: String? = expectedChecksumSHA256
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        let storedRate = maxBytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
        let storedConnections = preferredConnectionCount.flatMap { $0 > 0 ? $0 : nil }

        return try database.pool.write { db in
            if let projectID {
                guard try ProjectRecord.fetchOne(db, key: projectID) != nil else {
                    throw JobRepositoryError.unknownProject(projectID)
                }
            }

            let now = Date()
            let batchID = UUID().uuidString.lowercased()
            try BatchRecord(
                id: batchID,
                createdAt: now,
                source: source,
                originalItemCount: items.count,
                displayName: displayName
            ).insert(db)

            let sharedScheduleID: String?
            let initialState: String
            if let scheduleStartAt {
                let scheduleID = UUID().uuidString.lowercased()
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                let payload = "{\"startAt\":\"\(formatter.string(from: scheduleStartAt))\"}"
                try ScheduleRecord(
                    id: scheduleID,
                    recurrence: "once",
                    timeZonePolicy: "utc",
                    missedOccurrencePolicy: "runImmediately",
                    constraints: payload
                ).insert(db)
                sharedScheduleID = scheduleID
                initialState = "scheduled"
            } else {
                sharedScheduleID = nil
                initialState = "queued"
            }

            var jobIDs: [String] = []
            jobIDs.reserveCapacity(items.count)
            var position = 0
            for item in items {
                let categoryID = try categoryID(forStableKey: item.categoryStableKey, db: db)
                let resourceID = UUID().uuidString.lowercased()
                let jobID = UUID().uuidString.lowercased()
                let protocolKind = URL(string: item.url)?.scheme?.lowercased() ?? "http"
                let filename = FilenameSanitizer.filename(fromURLString: item.url)
                let destinationPath = try DestinationProfileRecord
                    .fetchOne(db, key: ProductionSeedIDs.destinationDownloads)
                    .flatMap { DestinationBookmark.pathDisplay(bookmarkData: $0.bookmarkData) }
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
                    checksum: storedChecksum,
                    identityRevision: 1
                ).insert(db)
                try JobRecord(
                    id: jobID,
                    batchID: batchID,
                    resourceID: resourceID,
                    state: initialState,
                    priority: 0,
                    queuePosition: position,
                    categoryID: categoryID,
                    projectID: projectID,
                    destinationProfileID: ProductionSeedIDs.destinationDownloads,
                    scheduleID: sharedScheduleID,
                    createdAt: now,
                    updatedAt: now,
                    revision: 1,
                    terminalReason: nil,
                    credentialProfileID: credentialProfileID,
                    proxyProfileID: proxyProfileID,
                    cookieProfileID: cookieProfileID,
                    customHeadersJSON: customHeadersJSON,
                    maxBytesPerSecond: storedRate,
                    preferredConnectionCount: storedConnections,
                    finalFilename: filename,
                    destinationPath: destinationPath
                ).insert(db)
                jobIDs.append(jobID)
                position += 1
            }
            return (batchID, jobIDs)
        }
    }

    /// Loads every job with its resource/category/project/tag associations using a
    /// constant number of statements (no N+1): one ordered `jobs` scan, up to three
    /// batched `WHERE id IN (...)` lookups (resources, categories, projects — each
    /// skipped entirely when its key set is empty), and one batched tag join.
    public static func fetchJobRows(
        database: EngineDatabase
    ) throws -> [(
        job: JobRecord,
        resource: ResourceRecord,
        category: CategoryRecord,
        projectName: String?,
        tagNames: [String],
        tagIDs: [String]
    )] {
        try fetchJobRows(database: database, jobIDs: nil)
    }

    /// Same projection as ``fetchJobRows(database:)``, optionally restricted to
    /// `jobIDs` for change-aware Library deltas.
    public static func fetchJobRows(
        database: EngineDatabase,
        jobIDs: Set<String>?
    ) throws -> [(
        job: JobRecord,
        resource: ResourceRecord,
        category: CategoryRecord,
        projectName: String?,
        tagNames: [String],
        tagIDs: [String]
    )] {
        try database.pool.read { db in
            let jobs: [JobRecord]
            if let jobIDs {
                guard !jobIDs.isEmpty else { return [] }
                jobs = try JobRecord
                    .filter(keys: jobIDs)
                    .order(Column("queuePosition").asc, Column("createdAt").asc)
                    .fetchAll(db)
            } else {
                jobs = try JobRecord
                    .order(Column("queuePosition").asc, Column("createdAt").asc)
                    .fetchAll(db)
            }
            guard !jobs.isEmpty else { return [] }

            let resourcesByID = try Dictionary(
                uniqueKeysWithValues: ResourceRecord
                    .filter(keys: Set(jobs.map(\.resourceID)))
                    .fetchAll(db)
                    .map { ($0.id, $0) }
            )
            let categoriesByID = try Dictionary(
                uniqueKeysWithValues: CategoryRecord
                    .filter(keys: Set(jobs.map(\.categoryID)))
                    .fetchAll(db)
                    .map { ($0.id, $0) }
            )
            let projectNamesByID = try Dictionary(
                uniqueKeysWithValues: ProjectRecord
                    .filter(keys: Set(jobs.compactMap(\.projectID)))
                    .fetchAll(db)
                    .map { ($0.id, $0.name) }
            )
            let (tagNamesByJobID, tagIDsByJobID) = try fetchTagsByJobID(
                jobIDs: jobs.map(\.id),
                db: db
            )

            var rows: [(JobRecord, ResourceRecord, CategoryRecord, String?, [String], [String])] = []
            rows.reserveCapacity(jobs.count)
            for job in jobs {
                guard let resource = resourcesByID[job.resourceID],
                      let category = categoriesByID[job.categoryID]
                else {
                    throw JobRepositoryError.jobNotFound(job.id)
                }
                let projectName = job.projectID.flatMap { projectNamesByID[$0] }
                rows.append((
                    job,
                    resource,
                    category,
                    projectName,
                    tagNamesByJobID[job.id] ?? [],
                    tagIDsByJobID[job.id] ?? []
                ))
            }
            return rows
        }
    }

    /// Single batched `job_tags`/`tags` join for the given job IDs, ordered by
    /// `jobID ASC, name ASC` so per-job tag arrays preserve the historical
    /// alphabetical-by-name ordering. No-op (no statement) when `jobIDs` is empty.
    private static func fetchTagsByJobID(
        jobIDs: [String],
        db: Database
    ) throws -> (names: [String: [String]], ids: [String: [String]]) {
        guard !jobIDs.isEmpty else { return ([:], [:]) }
        let placeholders = jobIDs.map { _ in "?" }.joined(separator: ", ")
        let tagRows = try Row.fetchAll(
            db,
            sql: """
            SELECT jt.jobID AS jobID, t.id AS tagID, t.name AS tagName
            FROM job_tags jt
            INNER JOIN tags t ON t.id = jt.tagID
            WHERE jt.jobID IN (\(placeholders))
            ORDER BY jt.jobID ASC, t.name ASC
            """,
            arguments: StatementArguments(jobIDs)
        )
        var names: [String: [String]] = [:]
        var ids: [String: [String]] = [:]
        for row in tagRows {
            let jobID: String = row["jobID"]
            names[jobID, default: []].append(row["tagName"])
            ids[jobID, default: []].append(row["tagID"])
        }
        return (names, ids)
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
    /// Active transfer states that cannot survive an agent crash mid-flight.
    /// `verifying` and `postProcessing` are reconciled via
    /// ``FinalizationIntentRepository/reconcileInterruptedFinalizations(database:)``.
    public static let interruptedTransferStates: Set<JobState> = [
        .connecting, .downloading, .merging
    ]

    /// Requeue jobs left in active transfer states after a crash/relaunch.
    /// Allowed sources: ``interruptedTransferStates``. Clears `terminalReason`,
    /// appends `recovery.requeued`, bumps revision. Returns the requeued job IDs
    /// (stable order by queuePosition, createdAt).
    public static func requeueInterruptedTransfers(database: EngineDatabase) throws -> [String] {
        try database.pool.write { db in
            let states = interruptedTransferStates.map(\.rawValue).sorted()
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
                guard let previous = JobState(rawValue: job.state),
                      interruptedTransferStates.contains(previous)
                else {
                    continue
                }
                job.state = JobState.queued.rawValue
                job.terminalReason = nil
                job.updatedAt = now
                job.revision += 1
                try job.update(db)

                let payload: String = if let data = try? JSONSerialization.data(
                    withJSONObject: [
                        "previousState": previous.rawValue,
                        "revision": job.revision
                    ] as [String: Any],
                    options: [.sortedKeys]
                ), let string = String(data: data, encoding: .utf8) {
                    string
                } else {
                    "{\"previousState\":\"\(previous.rawValue)\",\"revision\":\(job.revision)}"
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

    /// In-flight transfer states the orchestrator may requeue for pump pickup
    /// outside the ordinary adjacency graph (resume-after-abort, retry backoff).
    public static let requeueableActiveTransferStates: Set<JobState> = [
        .connecting, .downloading, .retryWaiting
    ]

    /// Requeues one in-flight transfer job so the orchestrator pump can resume it.
    /// Allowed sources: ``requeueableActiveTransferStates``. Clears `terminalReason`,
    /// appends `transfer.requeued`, bumps revision.
    public static func requeueActiveTransferJob(
        database: EngineDatabase,
        id: String
    ) throws -> Int {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id) else {
                throw JobRepositoryError.jobNotFound(id)
            }
            guard let current = JobState(rawValue: job.state) else {
                throw JobRepositoryError.unknownPersistedState(job.state)
            }
            guard requeueableActiveTransferStates.contains(current) else {
                throw JobRepositoryError.invalidRequeueSource(current)
            }
            let previousState = current.rawValue
            job.state = JobState.queued.rawValue
            job.terminalReason = nil
            job.updatedAt = Date()
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
                jobID: id,
                occurredAt: job.updatedAt,
                type: "transfer.requeued",
                sanitizedPayload: payload
            ).insert(db)
            return job.revision
        }
    }

    public static func updateJobState(
        database: EngineDatabase,
        id: String,
        state: JobState,
        terminalReason: String?,
        expectedRevision: Int?,
        resetTimelineForRestart: Bool = false
    ) throws -> Int {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id) else {
                throw JobRepositoryError.jobNotFound(id)
            }
            guard let current = JobState(rawValue: job.state) else {
                throw JobRepositoryError.unknownPersistedState(job.state)
            }
            if let expectedRevision, job.revision != expectedRevision {
                throw JobRepositoryError.revisionConflict(expected: expectedRevision, actual: job.revision)
            }
            guard current.canTransition(to: state) else {
                throw JobRepositoryError.invalidTransition(from: current, to: state)
            }
            try validateTerminalReason(state: state, terminalReason: terminalReason)

            job.state = state.rawValue
            job.terminalReason = terminalReason
            let now = Date()
            job.updatedAt = now
            if resetTimelineForRestart {
                JobLocationTimeline.clearForRestart(&job)
            }
            JobLocationTimeline.applyStateTransition(&job, from: current, to: state, at: now)
            if let profile = try DestinationProfileRecord.fetchOne(db, key: job.destinationProfileID) {
                JobLocationTimeline.refreshDestinationPath(&job, profile: profile)
            }
            job.revision += 1
            try job.update(db)

            let payload = Self.sanitizedStatePayload(
                state: state.rawValue,
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

    private static func validateTerminalReason(
        state: JobState,
        terminalReason: String?
    ) throws {
        if JobState.terminalReasonRequiring.contains(state) {
            guard let terminalReason,
                  let reason = TerminalReason(rawValue: terminalReason)
            else {
                throw JobRepositoryError.missingTerminalReason(state: state)
            }
            guard reason.impliedState == state else {
                throw JobRepositoryError.terminalReasonMismatch(
                    state: state,
                    reason: terminalReason
                )
            }
            return
        }
        guard terminalReason == nil else {
            throw JobRepositoryError.unexpectedTerminalReason(state: state)
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

    /// Newest-first event journal read (optional job filter). `limit` is clamped to 1…4096.
    public static func listEvents(
        database: EngineDatabase,
        jobID: String?,
        limit: Int
    ) throws -> [EventRecord] {
        let capped = min(max(limit, 1), 4096)
        return try database.pool.read { db in
            var request = EventRecord.order(Column("sequence").desc).limit(capped)
            if let jobID {
                request = request.filter(Column("jobID") == jobID)
            }
            return try request.fetchAll(db)
        }
    }

    /// Deletes all event rows for a job. Returns how many rows were removed.
    public static func clearEvents(database: EngineDatabase, jobID: String) throws -> Int {
        try database.pool.write { db in
            try EventRecord.filter(Column("jobID") == jobID).deleteAll(db)
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
            let destination: URL
            do {
                destination = try DestinationBookmark.resolveDirectory(bookmarkData: profile.bookmarkData)
            } catch {
                destination = try URL(
                    resolvingBookmarkData: profile.bookmarkData,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }
            let suggested = FilenameSanitizer.preferredFilename(
                contentDisposition: nil,
                urlString: resource.canonicalURL,
                existingEvidence: resource.filenameEvidence,
                contentType: resource.mimeEvidence
            )
            return TransferJobDetails(
                jobID: job.id,
                revision: job.revision,
                state: job.state,
                canonicalURL: resource.canonicalURL,
                destinationDirectory: destination,
                suggestedFilename: job.finalFilename ?? suggested,
                conflictPolicy: profile.conflictPolicy,
                expectedChecksum: resource.checksum,
                credentialProfileID: job.credentialProfileID,
                proxyProfileID: job.proxyProfileID,
                cookieProfileID: job.cookieProfileID,
                customHeadersJSON: job.customHeadersJSON,
                maxBytesPerSecond: job.maxBytesPerSecond,
                preferredConnectionCount: job.preferredConnectionCount,
                categorySubfolder: job.categorySubfolder
            )
        }
    }

    /// Decides, once and for all, which subfolder this job's file lands in.
    ///
    /// Idempotent by design: the first call stamps `categorySubfolder` from the
    /// job's category at that moment and every later call returns the stamped
    /// value, ignoring `enabled` and ignoring any subsequent category change. That
    /// is the whole point — a job whose folder moved between attempts would leave
    /// its `.partial` and `.segmap` behind at the old path and re-download from
    /// zero. Toggling the setting therefore affects new downloads only.
    ///
    /// Called after the probe has had its chance to upgrade a job out of `other`,
    /// so an unclassified link that turns out to be a video lands in `Videos`.
    /// Returns `nil` when the feature is off or the category yields no safe folder
    /// name; the caller then writes straight into the destination directory.
    @discardableResult
    public static func stampCategorySubfolder(
        database: EngineDatabase,
        jobID: String,
        enabled: Bool
    ) throws -> String? {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID) else {
                throw JobRepositoryError.jobNotFound(jobID)
            }
            if let stamped = job.categorySubfolder {
                return stamped
            }
            guard enabled else { return nil }
            guard let category = try CategoryRecord.fetchOne(db, key: job.categoryID),
                  let folder = CategoryFolderName.folderName(
                      forCategoryStableKey: category.stableKey
                  )
            else { return nil }
            job.categorySubfolder = folder
            // Keep the displayed location in step immediately rather than waiting
            // for the next state transition. Same helper that transition uses, so
            // there is one implementation of "where does this job's file live".
            if let profile = try DestinationProfileRecord.fetchOne(
                db, key: job.destinationProfileID
            ) {
                JobLocationTimeline.refreshDestinationPath(&job, profile: profile)
            }
            // No `revision` bump: this is agent-internal path bookkeeping, not state
            // a client holds an expected revision for — the same reason
            // `JobLocationTimeline` does not bump it. Bumping here would reject a
            // Pause or Cancel clicked between the last poll and this write, with a
            // revision conflict the user has no way to see.
            job.updatedAt = Date()
            try job.update(db)
            return folder
        }
    }

    /// Reads one job's transfer limits and integrity outcome for the inspector.
    /// Two `fetchOne` statements; not on the polled `listJobs` path.
    public static func loadTransferSettings(
        database: EngineDatabase,
        jobID: String
    ) throws -> JobTransferSettings {
        try database.pool.read { db in
            guard let job = try JobRecord.fetchOne(db, key: jobID),
                  let resource = try ResourceRecord.fetchOne(db, key: job.resourceID)
            else {
                throw JobRepositoryError.jobNotFound(jobID)
            }
            return JobTransferSettings(
                jobID: job.id,
                state: job.state,
                terminalReason: job.terminalReason,
                expectedChecksum: resource.checksum,
                maxBytesPerSecond: job.maxBytesPerSecond,
                preferredConnectionCount: job.preferredConnectionCount
            )
        }
    }

    public static func updateResourceIdentity(
        database: EngineDatabase,
        jobID: String,
        finalURL: String?,
        expectedSize: Int64?,
        etag: String?,
        mime: String?,
        contentDisposition: String? = nil
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
            let betterName = FilenameSanitizer.preferredFilename(
                contentDisposition: contentDisposition,
                urlString: finalURL ?? resource.canonicalURL,
                existingEvidence: resource.filenameEvidence,
                contentType: mime ?? resource.mimeEvidence
            )
            resource.filenameEvidence = betterName
            resource.identityRevision += 1
            try resource.update(db)
        }
    }

    /// Clears transfer identity size (and related resume validators) for a
    /// restart-from-scratch. Bumps `identityRevision`.
    public static func clearResourceIdentitySize(
        database: EngineDatabase,
        jobID: String
    ) throws {
        try database.pool.write { db in
            guard let job = try JobRecord.fetchOne(db, key: jobID),
                  var resource = try ResourceRecord.fetchOne(db, key: job.resourceID)
            else {
                throw JobRepositoryError.jobNotFound(jobID)
            }
            resource.expectedSize = nil
            resource.finalURL = nil
            resource.strongETag = nil
            resource.identityRevision += 1
            try resource.update(db)
        }
    }

    /// Sets absolute queue priority (`ORDER BY priority DESC`). Bumps revision.
    @discardableResult
    public static func setPriority(
        database: EngineDatabase,
        id: String,
        priority: Int
    ) throws -> Int {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id) else {
                throw JobRepositoryError.jobNotFound(id)
            }
            job.priority = priority
            job.updatedAt = Date()
            job.revision += 1
            try job.update(db)
            try EventRecord(
                jobID: id,
                occurredAt: job.updatedAt,
                type: "queue.priorityChanged",
                sanitizedPayload: "{\"priority\":\(priority),\"revision\":\(job.revision)}"
            ).insert(db)
            return job.revision
        }
    }

    /// Moves a job to an absolute `queuePosition` (lower = earlier among equal priority).
    /// Bumps revision; does not renumber siblings.
    @discardableResult
    public static func moveQueuePosition(
        database: EngineDatabase,
        id: String,
        queuePosition: Int
    ) throws -> Int {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id) else {
                throw JobRepositoryError.jobNotFound(id)
            }
            job.queuePosition = queuePosition
            job.updatedAt = Date()
            job.revision += 1
            try job.update(db)
            try EventRecord(
                jobID: id,
                occurredAt: job.updatedAt,
                type: "queue.positionChanged",
                sanitizedPayload: "{\"queuePosition\":\(queuePosition),\"revision\":\(job.revision)}"
            ).insert(db)
            return job.revision
        }
    }

    /// Deletes a job row (+ owned resource when unused). Does **not**
    /// touch on-disk destination files — callers pass `deleteFiles` over XPC when
    /// the user chooses “Remove Files”. Active jobs must be aborted by the
    /// engine before calling this; the row itself may be in any state.
    /// Returns the previous state for event/logging.
    @discardableResult
    public static func deleteTerminalJob(
        database: EngineDatabase,
        id: String
    ) throws -> String {
        try database.pool.write { db in
            guard let job = try JobRecord.fetchOne(db, key: id) else {
                throw JobRepositoryError.jobNotFound(id)
            }
            let previousState = job.state
            let resourceID = job.resourceID
            let scheduleID = job.scheduleID
            try job.delete(db)
            if try JobRecord.filter(Column("resourceID") == resourceID).fetchCount(db) == 0 {
                try ResourceRecord.deleteOne(db, key: resourceID)
            }
            if let scheduleID {
                let scheduleInUse = try JobRecord.filter(Column("scheduleID") == scheduleID).fetchCount(db) > 0
                if !scheduleInUse {
                    try ScheduleRecord.deleteOne(db, key: scheduleID)
                }
            }
            try EventRecord(
                jobID: nil,
                occurredAt: Date(),
                type: "library.jobDeleted",
                sanitizedPayload: "{\"previousState\":\"\(previousState)\"}"
            ).insert(db)
            return previousState
        }
    }
}

public enum JobRepositoryError: Error, Equatable, Sendable {
    case unknownCategory(String)
    case unknownProject(String)
    case jobNotFound(String)
    case revisionConflict(expected: Int, actual: Int)
    case notTerminal(String, state: String)
    case invalidFilename(String)
    case renameWhileActive(String)
    case renameTargetExists(String)
    case unknownPersistedState(String)
    case invalidTransition(from: JobState, to: JobState)
    case missingTerminalReason(state: JobState)
    case unexpectedTerminalReason(state: JobState)
    case terminalReasonMismatch(state: JobState, reason: String)
    case invalidRequeueSource(JobState)
}
