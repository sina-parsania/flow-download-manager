// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import GRDB
import Persistence
import SharedSecurity
import XCTest

/// Thread-safe statement counter for `db.trace` assertions. GRDB invokes the
/// trace callback on the traced connection's own dispatch queue, which may
/// differ from the calling test thread.
private final class StatementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    /// Zeroes the count. Used to discard statements issued while opening/migrating
    /// the traced connection, so assertions cover only the call under test.
    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class JobRepositoryTests: XCTestCase {
    private func openTempDatabase() throws -> (EngineDatabase, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-jobrepo-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("engine.sqlite")
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(
            database: database,
            defaultDestinationDirectory: downloads
        )
        return (database, root, downloads)
    }

    private func seedJobInState(
        _ database: EngineDatabase,
        state: JobState
    ) throws -> String {
        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [(url: "https://example.test/seed.bin", categoryStableKey: "other")]
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)
        guard state != .queued else { return jobID }
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID) else { return }
            job.state = state.rawValue
            if JobState.terminalReasonRequiring.contains(state) {
                job.terminalReason = TerminalReason.networkUnavailable.rawValue
            } else {
                job.terminalReason = nil
            }
            try job.update(db)
        }
        return jobID
    }

    private func terminalReasonForTransition(to target: JobState) -> String? {
        switch target {
        case .failed:
            TerminalReason.networkUnavailable.rawValue
        case .cancelled:
            TerminalReason.userCancelled.rawValue
        default:
            nil
        }
    }

    func testEveryTransitionPairEnforcedAtPersistence() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        for from in JobState.allCases {
            for to in JobState.allCases {
                let jobID = try seedJobInState(database, state: from)
                let before = try database.pool.read { db -> (String, Int, Int) in
                    let job = try JobRecord.fetchOne(db, key: jobID)
                    let events = try EventRecord.filter(Column("jobID") == jobID).fetchCount(db)
                    return (job?.state ?? "", job?.revision ?? 0, events)
                }
                let reason = terminalReasonForTransition(to: to)
                let shouldSucceed = from.canTransition(to: to)

                if shouldSucceed {
                    _ = try JobRepository.updateJobState(
                        database: database,
                        id: jobID,
                        state: to,
                        terminalReason: reason,
                        expectedRevision: nil
                    )
                    let after = try database.pool.read { db -> (String, Int, Int) in
                        let job = try JobRecord.fetchOne(db, key: jobID)
                        let events = try EventRecord.filter(Column("jobID") == jobID).fetchCount(db)
                        return (job?.state ?? "", job?.revision ?? 0, events)
                    }
                    XCTAssertEqual(after.0, to.rawValue, "\(from) → \(to) should persist")
                    XCTAssertEqual(after.1, before.1 + 1, "\(from) → \(to) should bump revision")
                    XCTAssertEqual(after.2, before.2 + 1, "\(from) → \(to) should append event")
                } else {
                    XCTAssertThrowsError(
                        try JobRepository.updateJobState(
                            database: database,
                            id: jobID,
                            state: to,
                            terminalReason: reason,
                            expectedRevision: nil
                        )
                    ) { error in
                        guard case let JobRepositoryError.invalidTransition(current, target) = error else {
                            return XCTFail("expected invalidTransition for \(from) → \(to), got \(error)")
                        }
                        XCTAssertEqual(current, from)
                        XCTAssertEqual(target, to)
                    }
                    let after = try database.pool.read { db -> (String, Int, Int) in
                        let job = try JobRecord.fetchOne(db, key: jobID)
                        let events = try EventRecord.filter(Column("jobID") == jobID).fetchCount(db)
                        return (job?.state ?? "", job?.revision ?? 0, events)
                    }
                    XCTAssertEqual(after.0, before.0, "\(from) → \(to) must not mutate persistence state")
                    XCTAssertEqual(after.1, before.1, "\(from) → \(to) must not mutate persistence revision")
                    XCTAssertEqual(after.2, before.2, "\(from) → \(to) must not mutate persistence events")
                }
            }
        }
    }

    func testSchemaRejectsUnknownPersistedStateWrites() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let jobID = try seedJobInState(database, state: .queued)
        // jobs.state CHECK matches JobState — unknown values cannot be seeded, so
        // updateJobState's unknownPersistedState path is defense for schema drift.
        XCTAssertNil(JobState(rawValue: "not_a_real_state"))
        XCTAssertThrowsError(
            try database.pool.write { db in
                guard var job = try JobRecord.fetchOne(db, key: jobID) else {
                    XCTFail("seeded job missing")
                    return
                }
                job.state = "not_a_real_state"
                try job.update(db)
            }
        )
    }

    func testCompletedStateRejectsTerminalReason() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let jobID = try seedJobInState(database, state: .postProcessing)
        XCTAssertThrowsError(
            try JobRepository.updateJobState(
                database: database,
                id: jobID,
                state: .completed,
                terminalReason: "networkUnavailable",
                expectedRevision: nil
            )
        ) { error in
            guard case JobRepositoryError.unexpectedTerminalReason(state: .completed) = error else {
                XCTFail("expected unexpectedTerminalReason, got \(error)")
                return
            }
        }
    }

    func testRequeueActiveTransferJobFromRetryWaiting() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let jobID = try seedJobInState(database, state: .retryWaiting)
        let revision = try JobRepository.requeueActiveTransferJob(database: database, id: jobID)
        XCTAssertEqual(revision, 2)

        let rows = try JobRepository.fetchJobRows(database: database)
        XCTAssertEqual(rows.first?.job.state, JobState.queued.rawValue)
        let events = try JobRepository.listEvents(database: database, jobID: jobID, limit: 10)
        XCTAssertTrue(events.contains { $0.type == "transfer.requeued" })
    }

    func testRequeueActiveTransferJobRejectsQueuedSource() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let jobID = try seedJobInState(database, state: .queued)
        XCTAssertThrowsError(
            try JobRepository.requeueActiveTransferJob(database: database, id: jobID)
        ) { error in
            guard case JobRepositoryError.invalidRequeueSource(.queued) = error else {
                XCTFail("expected invalidRequeueSource, got \(error)")
                return
            }
        }
    }

    func testEnsureProductionSeedInsertBatchAndFetchQueuedRows() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        // Idempotent reseed must not fail or duplicate categories.
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try JobRepository.ensureProductionSeed(
            database: database,
            defaultDestinationDirectory: downloads
        )

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: "Sample batch",
            items: [
                (url: "https://example.test/a.mp4", categoryStableKey: "videos"),
                (url: "https://example.test/b.zip", categoryStableKey: "archives")
            ]
        )
        XCTAssertEqual(result.jobIDs.count, 2)

        let rows = try JobRepository.fetchJobRows(database: database)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.job.state), ["queued", "queued"])
        XCTAssertEqual(rows.map(\.category.stableKey), ["videos", "archives"])
        XCTAssertEqual(rows.map(\.resource.canonicalURL), [
            "https://example.test/a.mp4",
            "https://example.test/b.zip"
        ])

        let queued = try JobRepository.fetchQueuedJobIDs(database: database, limit: 10)
        XCTAssertEqual(queued, result.jobIDs)

        let details = try JobRepository.loadJobForTransfer(database: database, id: result.jobIDs[0])
        XCTAssertEqual(details.canonicalURL, "https://example.test/a.mp4")
        XCTAssertEqual(details.suggestedFilename, "a.mp4")
        XCTAssertFalse(details.destinationDirectory.path.isEmpty)
        XCTAssertNil(details.credentialProfileID)
        XCTAssertNil(details.proxyProfileID)
        XCTAssertNil(details.cookieProfileID)
        XCTAssertNil(details.customHeadersJSON)
        XCTAssertNil(details.expectedChecksum)
        XCTAssertNil(details.maxBytesPerSecond)
        XCTAssertNil(details.preferredConnectionCount)
    }

    func testInsertBatchPersistsChecksumAndPerJobLimits() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let digest = String(repeating: "0123456789abcdef", count: 4)
        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [(url: "https://example.test/a.iso", categoryStableKey: "archives")],
            expectedChecksumSHA256: digest.uppercased(),
            maxBytesPerSecond: 2_500_000,
            preferredConnectionCount: 6
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)

        // The transfer path reads the checksum it will verify against, plus the
        // overrides that shape the download options.
        let details = try JobRepository.loadJobForTransfer(database: database, id: jobID)
        XCTAssertEqual(details.expectedChecksum, digest)
        XCTAssertEqual(details.maxBytesPerSecond, 2_500_000)
        XCTAssertEqual(details.preferredConnectionCount, 6)

        let settings = try JobRepository.loadTransferSettings(database: database, jobID: jobID)
        XCTAssertEqual(settings.expectedChecksum, digest)
        XCTAssertEqual(settings.maxBytesPerSecond, 2_500_000)
        XCTAssertEqual(settings.preferredConnectionCount, 6)
        XCTAssertEqual(settings.state, "queued")
        XCTAssertNil(settings.terminalReason)
    }

    func testInsertBatchTreatsBlankAndNonPositiveOverridesAsAbsent() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [(url: "https://example.test/a.iso", categoryStableKey: "archives")],
            expectedChecksumSHA256: "   ",
            maxBytesPerSecond: 0,
            preferredConnectionCount: -3
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)
        let details = try JobRepository.loadJobForTransfer(database: database, id: jobID)
        XCTAssertNil(details.expectedChecksum)
        XCTAssertNil(details.maxBytesPerSecond)
        XCTAssertNil(details.preferredConnectionCount)
    }

    /// `fetchJobRows` must execute a constant-statement plan (a handful of batched
    /// queries), not one-plus-N-per-association. With 20 jobs each carrying a tag,
    /// the historical N+1 shape would issue on the order of `1 + 4 * 20` statements;
    /// the set-based plan stays in the single digits regardless of job count.
    func testFetchJobRowsIssuesBoundedStatementCountNotNPlusOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-jobrepo-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("engine.sqlite")
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let seedDatabase = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(
            database: seedDatabase,
            defaultDestinationDirectory: downloads
        )

        let jobCount = 20
        let items = (0 ..< jobCount).map {
            (url: "https://example.test/file\($0).bin", categoryStableKey: "other")
        }
        let result = try JobRepository.insertBatch(
            database: seedDatabase,
            source: "paste",
            displayName: nil,
            items: items
        )
        let tagID = try OrganizationRepository.createTag(database: seedDatabase, name: "batch")
        for jobID in result.jobIDs {
            try OrganizationRepository.attachTagToJob(database: seedDatabase, jobID: jobID, tagID: tagID)
        }

        let counter = StatementCounter()
        var tracedConfiguration = DatabaseConfiguration.make()
        tracedConfiguration.prepareDatabase { db in
            db.trace(options: .statement) { _ in counter.increment() }
        }
        let tracedDatabase = try EngineDatabase(url: dbURL, configuration: tracedConfiguration)

        // First call warms up the reader connection (GRDB's one-time-per-connection
        // schema-cache and primary-key introspection statements, unrelated to job
        // count). Only the second call — pure query-plan cost — is asserted below.
        _ = try JobRepository.fetchJobRows(database: tracedDatabase)
        counter.reset()

        let rows = try JobRepository.fetchJobRows(database: tracedDatabase)
        XCTAssertEqual(rows.count, jobCount)
        XCTAssertTrue(rows.allSatisfy { $0.tagNames == ["batch"] })
        XCTAssertTrue(rows.allSatisfy { $0.tagIDs == [tagID] })

        // Constant plan on a warm connection: BEGIN, jobs, resources, categories,
        // projects, tags, COMMIT — 7 statements, independent of job count. The
        // historical N+1 shape would have issued on the order of `1 + 4 * jobCount`
        // (81) statements for this fixture.
        XCTAssertGreaterThan(counter.count, 0)
        XCTAssertLessThanOrEqual(counter.count, 10)
    }

    func testInsertBatchPersistsProfilesProjectAndSchedule() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let projectID = try OrganizationRepository.createProject(
            database: database,
            name: "Film"
        )
        let store = InMemorySecretStore()
        let credID = UUID().uuidString.lowercased()
        let proxyID = UUID().uuidString.lowercased()
        try ProfileRepository.upsertCredentialProfile(
            database: database,
            id: credID,
            metadata: CredentialProfileMetadata(displayName: "Cred", username: "u"),
            passwordUTF8: Data("p".utf8),
            secretStore: store
        )
        try ProfileRepository.upsertProxyProfile(
            database: database,
            id: proxyID,
            metadata: ProxyProfileMetadata(
                displayName: "Proxy", kind: "http", host: "127.0.0.1", port: 8080
            )
        )
        let startAt = Date().addingTimeInterval(3600)
        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [(url: "https://example.test/a.mp4", categoryStableKey: "videos")],
            credentialProfileID: credID,
            proxyProfileID: proxyID,
            cookieProfileID: nil,
            customHeadersJSON: #"[{"name":"X-A","value":"1"}]"#,
            projectID: projectID,
            scheduleStartAt: startAt
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)
        let rows = try JobRepository.fetchJobRows(database: database)
        let job = try XCTUnwrap(rows.first?.job)
        XCTAssertEqual(job.id, jobID)
        XCTAssertEqual(job.state, "scheduled")
        XCTAssertEqual(job.projectID, projectID)
        XCTAssertEqual(job.credentialProfileID, credID)
        XCTAssertEqual(job.proxyProfileID, proxyID)
        XCTAssertEqual(job.customHeadersJSON, #"[{"name":"X-A","value":"1"}]"#)
        XCTAssertNotNil(job.scheduleID)
        XCTAssertEqual(rows.first?.projectName, "Film")
        let queued = try JobRepository.fetchQueuedJobIDs(database: database, limit: 10)
        XCTAssertTrue(queued.isEmpty)
    }

    func testUpdateJobStateWritesEventJournal() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [
                (url: "https://example.test/file.bin", categoryStableKey: "other")
            ]
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)

        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: .connecting,
            terminalReason: nil,
            expectedRevision: 1
        )

        let events = try database.pool.read { db in
            try EventRecord
                .filter(Column("jobID") == jobID)
                .order(Column("sequence").asc)
                .fetchAll(db)
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "state.changed")
        let payload = try XCTUnwrap(events[0].sanitizedPayload)
        XCTAssertTrue(payload.contains("\"state\":\"connecting\""))
        XCTAssertFalse(payload.contains("example.test"))
        XCTAssertFalse(payload.lowercased().contains("password"))
    }

    func testAppendEventWritesSanitizedRow() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [
                (url: "https://example.test/file.bin", categoryStableKey: "other")
            ]
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)
        try JobRepository.appendEvent(
            database: database,
            jobID: jobID,
            type: "transfer.note",
            sanitizedPayload: "{\"segmentCount\":2}"
        )
        let count = try database.count(EventRecord.self)
        XCTAssertEqual(count, 1)
    }

    func testAppendAndListEventsFiltersByJobAndLimit() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [
                (url: "https://example.test/a.bin", categoryStableKey: "other"),
                (url: "https://example.test/b.bin", categoryStableKey: "other")
            ]
        )
        let jobA = try XCTUnwrap(result.jobIDs.first)
        let jobB = try XCTUnwrap(result.jobIDs.last)

        try JobRepository.appendEvent(
            database: database, jobID: jobA, type: "note.a1", sanitizedPayload: "{\"n\":1}"
        )
        try JobRepository.appendEvent(
            database: database, jobID: jobA, type: "note.a2", sanitizedPayload: "{\"n\":2}"
        )
        try JobRepository.appendEvent(
            database: database, jobID: jobB, type: "note.b1", sanitizedPayload: "{\"n\":3}"
        )

        let forA = try JobRepository.listEvents(database: database, jobID: jobA, limit: 10)
        XCTAssertEqual(forA.count, 2)
        XCTAssertEqual(forA.map(\.type), ["note.a2", "note.a1"])

        let limited = try JobRepository.listEvents(database: database, jobID: jobA, limit: 1)
        XCTAssertEqual(limited.count, 1)
        XCTAssertEqual(limited[0].type, "note.a2")

        let all = try JobRepository.listEvents(database: database, jobID: nil, limit: 50)
        XCTAssertEqual(all.count, 3)

        let deleted = try JobRepository.clearEvents(database: database, jobID: jobA)
        XCTAssertEqual(deleted, 2)
        let remainingA = try JobRepository.listEvents(database: database, jobID: jobA, limit: 10)
        XCTAssertTrue(remainingA.isEmpty)
        let remainingB = try JobRepository.listEvents(database: database, jobID: jobB, limit: 10)
        XCTAssertEqual(remainingB.count, 1)
    }

    func testUpdateJobStateRevisionCheck() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [
                (url: "https://example.test/file.bin", categoryStableKey: "other")
            ]
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)

        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: .connecting,
            terminalReason: nil,
            expectedRevision: 1
        )

        XCTAssertThrowsError(
            try JobRepository.updateJobState(
                database: database,
                id: jobID,
                state: .downloading,
                terminalReason: nil,
                expectedRevision: 1
            )
        ) { error in
            guard case JobRepositoryError.revisionConflict = error else {
                return XCTFail("expected revisionConflict, got \(error)")
            }
        }

        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: .downloading,
            terminalReason: nil,
            expectedRevision: 2
        )

        let rows = try JobRepository.fetchJobRows(database: database)
        XCTAssertEqual(rows.first?.job.state, "downloading")
        XCTAssertEqual(rows.first?.job.revision, 3)
    }

    func testRequeueInterruptedTransfersMovesDownloadingToQueued() throws {
        let (database, root, downloads) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [
                (url: "https://example.test/interrupted.bin", categoryStableKey: "other")
            ]
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)

        // Optional partial file on disk (resume path); recovery does not require it.
        let partial = downloads.appendingPathComponent("interrupted.bin.partial")
        try Data("partial".utf8).write(to: partial)

        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: .connecting,
            terminalReason: nil,
            expectedRevision: nil
        )
        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: .downloading,
            terminalReason: nil,
            expectedRevision: nil
        )

        let requeued = try JobRepository.requeueInterruptedTransfers(database: database)
        XCTAssertEqual(requeued, [jobID])

        let rows = try JobRepository.fetchJobRows(database: database)
        let job = try XCTUnwrap(rows.first?.job)
        XCTAssertEqual(job.state, "queued")
        XCTAssertNil(job.terminalReason)
        XCTAssertEqual(job.revision, 4)

        let events = try database.pool.read { db in
            try EventRecord
                .filter(Column("jobID") == jobID)
                .filter(Column("type") == "recovery.requeued")
                .fetchAll(db)
        }
        XCTAssertEqual(events.count, 1)
        let payload = try XCTUnwrap(events[0].sanitizedPayload)
        XCTAssertTrue(payload.contains("\"previousState\":\"downloading\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    func testSetPriorityAndMoveQueuePositionReorderQueuedJobs() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [
                (url: "https://example.test/a.bin", categoryStableKey: "other"),
                (url: "https://example.test/b.bin", categoryStableKey: "other"),
                (url: "https://example.test/c.bin", categoryStableKey: "other")
            ]
        )
        XCTAssertEqual(result.jobIDs.count, 3)

        _ = try JobRepository.setPriority(database: database, id: result.jobIDs[2], priority: 10)
        _ = try JobRepository.moveQueuePosition(database: database, id: result.jobIDs[1], queuePosition: 50)

        let queued = try JobRepository.fetchQueuedJobIDs(database: database, limit: 10)
        // Higher priority first; among remaining, lower queuePosition wins.
        XCTAssertEqual(queued.first, result.jobIDs[2])
        XCTAssertEqual(queued[1], result.jobIDs[0])
        XCTAssertEqual(queued[2], result.jobIDs[1])

        let rows = try JobRepository.fetchJobRows(database: database)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.job.id, $0.job) })
        XCTAssertEqual(byID[result.jobIDs[2]]?.priority, 10)
        XCTAssertEqual(byID[result.jobIDs[1]]?.queuePosition, 50)
    }

    func testDeleteJobRemovesAnyStateAndLeavesOnDiskFilesAlone() throws {
        let (database, root, downloads) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [
                (url: "https://example.test/keep.bin", categoryStableKey: "other"),
                (url: "https://example.test/done.bin", categoryStableKey: "other"),
                (url: "https://example.test/fail.bin", categoryStableKey: "other")
            ]
        )

        // Queued (non-terminal) jobs may be removed from the library.
        let queuedPrevious = try JobRepository.deleteTerminalJob(
            database: database,
            id: result.jobIDs[0]
        )
        XCTAssertEqual(queuedPrevious, "queued")

        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: result.jobIDs[1]) else { return }
            job.state = JobState.completed.rawValue
            job.terminalReason = nil
            job.revision += 1
            try job.update(db)
        }
        let completedFile = downloads.appendingPathComponent("done.bin")
        try Data([0x01, 0x02]).write(to: completedFile)

        let previous = try JobRepository.deleteTerminalJob(database: database, id: result.jobIDs[1])
        XCTAssertEqual(previous, "completed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedFile.path))

        _ = try JobRepository.updateJobState(
            database: database,
            id: result.jobIDs[2],
            state: .failed,
            terminalReason: "notFound",
            expectedRevision: nil
        )
        _ = try JobRepository.deleteTerminalJob(database: database, id: result.jobIDs[2])

        let remaining = try JobRepository.fetchJobRows(database: database)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRequeueInterruptedTransfersIgnoresQueuedAndTerminal() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [
                (url: "https://example.test/a.bin", categoryStableKey: "other"),
                (url: "https://example.test/b.bin", categoryStableKey: "other")
            ]
        )
        _ = try JobRepository.updateJobState(
            database: database,
            id: result.jobIDs[1],
            state: .failed,
            terminalReason: "notFound",
            expectedRevision: nil
        )

        let requeued = try JobRepository.requeueInterruptedTransfers(database: database)
        XCTAssertTrue(requeued.isEmpty)
    }

    func testClearResourceIdentitySizeClearsExpectedSizeAndValidators() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [(url: "https://example.test/restart.bin", categoryStableKey: "other")]
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)

        try JobRepository.updateResourceIdentity(
            database: database,
            jobID: jobID,
            finalURL: "https://example.test/restart.bin",
            expectedSize: 4096,
            etag: "\"abc\"",
            mime: "application/octet-stream"
        )

        try JobRepository.clearResourceIdentitySize(database: database, jobID: jobID)

        let cleared = try database.pool.read { db -> (Int64?, String?, String?, Int) in
            guard let job = try JobRecord.fetchOne(db, key: jobID),
                  let resource = try ResourceRecord.fetchOne(db, key: job.resourceID)
            else {
                throw JobRepositoryError.jobNotFound(jobID)
            }
            return (resource.expectedSize, resource.finalURL, resource.strongETag, resource.identityRevision)
        }
        XCTAssertNil(cleared.0)
        XCTAssertNil(cleared.1)
        XCTAssertNil(cleared.2)
        XCTAssertGreaterThanOrEqual(cleared.3, 2)
    }

    func testUpgradeCategoryFromOtherOnlyWhenOther() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [
                (url: "https://cdn.example/stream/watch/ep1", categoryStableKey: "other"),
                (url: "https://cdn.example/doc.pdf", categoryStableKey: "documents")
            ]
        )
        let otherID = try XCTUnwrap(result.jobIDs.first)
        let docsID = try XCTUnwrap(result.jobIDs.last)

        XCTAssertTrue(
            try JobRepository.upgradeCategoryFromOther(
                database: database,
                jobID: otherID,
                categoryStableKey: "videos"
            )
        )
        XCTAssertFalse(
            try JobRepository.upgradeCategoryFromOther(
                database: database,
                jobID: docsID,
                categoryStableKey: "videos"
            )
        )

        let rows = try JobRepository.fetchJobRows(database: database)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.job.id, $0.category.stableKey) })
        XCTAssertEqual(byID[otherID], "videos")
        XCTAssertEqual(byID[docsID], "documents")
    }

    func testSetJobFilenameUpdatesEvidenceAndRefusesActive() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [(url: "https://cdn.example/film.mkv", categoryStableKey: "videos")]
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)

        let renamed = try JobRepository.setJobFilename(
            database: database,
            jobID: jobID,
            filename: "My Film.mkv"
        )
        XCTAssertEqual(renamed, "My Film.mkv")

        let details = try JobRepository.loadJobForTransfer(database: database, id: jobID)
        XCTAssertEqual(details.suggestedFilename, "My Film.mkv")

        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: .connecting,
            terminalReason: nil,
            expectedRevision: nil
        )
        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: .downloading,
            terminalReason: nil,
            expectedRevision: nil
        )
        XCTAssertThrowsError(
            try JobRepository.setJobFilename(
                database: database,
                jobID: jobID,
                filename: "Nope.mkv"
            )
        ) { error in
            XCTAssertEqual(error as? JobRepositoryError, .renameWhileActive("downloading"))
        }
    }
}
