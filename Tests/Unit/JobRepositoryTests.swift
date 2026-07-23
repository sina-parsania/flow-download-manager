// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Persistence
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
}
