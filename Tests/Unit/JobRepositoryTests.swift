// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Persistence
import SharedSecurity
import XCTest

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
            state: "connecting",
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
            state: "connecting",
            terminalReason: nil,
            expectedRevision: 1
        )

        XCTAssertThrowsError(
            try JobRepository.updateJobState(
                database: database,
                id: jobID,
                state: "downloading",
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
            state: "downloading",
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
            state: "downloading",
            terminalReason: "networkUnavailable",
            expectedRevision: nil
        )

        let requeued = try JobRepository.requeueInterruptedTransfers(database: database)
        XCTAssertEqual(requeued, [jobID])

        let rows = try JobRepository.fetchJobRows(database: database)
        let job = try XCTUnwrap(rows.first?.job)
        XCTAssertEqual(job.state, "queued")
        XCTAssertNil(job.terminalReason)
        XCTAssertEqual(job.revision, 3)

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
            state: "failed",
            terminalReason: "notFound",
            expectedRevision: nil
        )

        let requeued = try JobRepository.requeueInterruptedTransfers(database: database)
        XCTAssertTrue(requeued.isEmpty)
    }
}
