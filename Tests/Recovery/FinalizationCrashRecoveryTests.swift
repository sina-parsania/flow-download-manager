// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import GRDB
import Persistence
import XCTest

/// Crash-boundary reconciliation for durable finalization intents.
final class FinalizationCrashRecoveryTests: XCTestCase {
    private func openFixture(
        filename: String = "crash.bin"
    ) throws -> (EngineDatabase, URL, URL, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-finalization-crash-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("engine.sqlite")
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(
            database: database,
            defaultDestinationDirectory: downloads
        )
        let result = try JobRepository.insertBatch(
            database: database,
            source: "paste",
            displayName: nil,
            items: [(url: "https://example.test/\(filename)", categoryStableKey: "other")]
        )
        let jobID = try XCTUnwrap(result.jobIDs.first)
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
        return (database, root, downloads, jobID)
    }

    private func beginPreparedIntent(
        database: EngineDatabase,
        jobID: String,
        downloads: URL,
        bytes: Data,
        zipAutoExtract: Bool = false
    ) throws {
        let partial = downloads.appendingPathComponent("crash.bin.partial")
        try bytes.write(to: partial)
        _ = try FinalizationIntentRepository.beginVerification(
            database: database,
            jobID: jobID,
            finalFilename: "crash.bin",
            partialFilename: "crash.bin.partial",
            expectedByteSize: Int64(bytes.count),
            expectedChecksum: nil,
            zipAutoExtract: zipAutoExtract
        )
    }

    func testAfterIntentBeforeRenamePartialRemainsAndResumeIsRequested() throws {
        let (database, root, downloads, jobID) = try openFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data(repeating: 0xAB, count: 16)
        try beginPreparedIntent(database: database, jobID: jobID, downloads: downloads, bytes: bytes)

        let outcomes = try FinalizationIntentRepository.reconcileInterruptedFinalizations(
            database: database
        )
        XCTAssertEqual(outcomes, [
            FinalizationRecoveryOutcome(jobID: jobID, action: .needsResumePromotion)
        ])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: downloads.appendingPathComponent("crash.bin.partial").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: downloads.appendingPathComponent("crash.bin").path
        ))

        let resumeIDs = try FinalizationIntentRepository.fetchJobsNeedingFinalizationResume(
            database: database,
            limit: 10
        )
        XCTAssertEqual(resumeIDs, [jobID])
    }

    func testAfterRenameBeforePromotedCommitCompletesWithoutSecondTransfer() throws {
        let (database, root, downloads, jobID) = try openFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data(repeating: 0xCD, count: 8)
        try beginPreparedIntent(database: database, jobID: jobID, downloads: downloads, bytes: bytes)
        let final = downloads.appendingPathComponent("crash.bin")
        try bytes.write(to: final)
        try? FileManager.default.removeItem(at: downloads.appendingPathComponent("crash.bin.partial"))

        let first = try FinalizationIntentRepository.reconcileInterruptedFinalizations(
            database: database
        )
        XCTAssertEqual(first, [FinalizationRecoveryOutcome(jobID: jobID, action: .completed)])

        let second = try FinalizationIntentRepository.reconcileInterruptedFinalizations(
            database: database
        )
        XCTAssertTrue(second.isEmpty)

        let rows = try JobRepository.fetchJobRows(database: database)
        XCTAssertEqual(rows.first?.job.state, JobState.completed.rawValue)
        XCTAssertEqual(try Data(contentsOf: final), bytes)
    }

    func testAfterPromotedCommitRequestsPostProcessingForZip() throws {
        let (database, root, downloads, jobID) = try openFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])
        try beginPreparedIntent(
            database: database,
            jobID: jobID,
            downloads: downloads,
            bytes: bytes,
            zipAutoExtract: true
        )
        _ = try FinalizationIntentRepository.markPromoted(database: database, jobID: jobID)
        let final = downloads.appendingPathComponent("crash.bin")
        try bytes.write(to: final)
        try? FileManager.default.removeItem(at: downloads.appendingPathComponent("crash.bin.partial"))

        let outcomes = try FinalizationIntentRepository.reconcileInterruptedFinalizations(
            database: database
        )
        XCTAssertEqual(outcomes, [
            FinalizationRecoveryOutcome(jobID: jobID, action: .needsPostProcessing)
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
    }

    func testAmbiguousPartialAndFinalNeverDeletesUserFiles() throws {
        let (database, root, downloads, jobID) = try openFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data(repeating: 0x01, count: 4)
        try beginPreparedIntent(database: database, jobID: jobID, downloads: downloads, bytes: bytes)
        let partial = downloads.appendingPathComponent("crash.bin.partial")
        let final = downloads.appendingPathComponent("crash.bin")
        try bytes.write(to: partial)
        try bytes.write(to: final)

        let outcomes = try FinalizationIntentRepository.reconcileInterruptedFinalizations(
            database: database
        )
        XCTAssertEqual(
            outcomes,
            [FinalizationRecoveryOutcome(jobID: jobID, action: .failed(reason: .destinationUnavailable))]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
    }

    func testMissingIntentOnVerifyingFailsWithoutDeletingFiles() throws {
        let (database, root, downloads, jobID) = try openFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("orphan".utf8)
        let partial = downloads.appendingPathComponent("crash.bin.partial")
        try bytes.write(to: partial)
        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: .verifying,
            terminalReason: nil,
            expectedRevision: nil
        )

        let outcomes = try FinalizationIntentRepository.reconcileInterruptedFinalizations(
            database: database
        )
        XCTAssertEqual(
            outcomes,
            [FinalizationRecoveryOutcome(jobID: jobID, action: .failed(reason: .databaseRecoveryRequired))]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        let requeued = try JobRepository.requeueInterruptedTransfers(database: database)
        XCTAssertTrue(requeued.isEmpty)
    }

    func testCompletedJobCleansStaleIntent() throws {
        let (database, root, downloads, jobID) = try openFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("done".utf8)
        try beginPreparedIntent(database: database, jobID: jobID, downloads: downloads, bytes: bytes)
        _ = try FinalizationIntentRepository.completeFinalization(database: database, jobID: jobID)

        let now = Date()
        try database.pool.write { db in
            try FinalizationIntentRecord(
                jobID: jobID,
                destinationProfileID: ProductionSeedIDs.destinationDownloads,
                finalFilename: "crash.bin",
                partialFilename: "crash.bin.partial",
                expectedByteSize: Int64(bytes.count),
                expectedChecksum: nil,
                stage: FinalizationIntentStage.promoted.rawValue,
                zipAutoExtract: false,
                revision: 1,
                createdAt: now,
                updatedAt: now
            ).insert(db)
        }

        let outcomes = try FinalizationIntentRepository.reconcileInterruptedFinalizations(
            database: database
        )
        XCTAssertEqual(outcomes, [FinalizationRecoveryOutcome(jobID: jobID, action: .completed)])
        XCTAssertNil(try FinalizationIntentRepository.fetchIntent(database: database, jobID: jobID))
    }
}
