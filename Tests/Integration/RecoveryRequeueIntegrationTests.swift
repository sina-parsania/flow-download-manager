// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Persistence
import XCTest

/// Lightweight recovery check: interrupted downloading jobs become queued on requeue helper.
final class RecoveryRequeueIntegrationTests: XCTestCase {
    func testRequeueInterruptedDownloadingJob() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-recovery-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("engine.sqlite")
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(
            database: database,
            defaultDestinationDirectory: downloads
        )
        let inserted = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [(url: "http://127.0.0.1/file.bin", categoryStableKey: "other")]
        )
        let jobID = try XCTUnwrap(inserted.jobIDs.first)
        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: "verifying",
            terminalReason: nil,
            expectedRevision: nil
        )

        let requeued = try JobRepository.requeueInterruptedTransfers(database: database)
        XCTAssertEqual(requeued, [jobID])
        let rows = try JobRepository.fetchJobRows(database: database)
        XCTAssertEqual(rows.first?.job.state, "queued")
    }
}
