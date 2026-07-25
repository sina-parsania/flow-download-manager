// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import Persistence
import XCTest

/// Interrupted verifying jobs with durable intents are reconciled, not requeued.
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
        XCTAssertEqual(rows.first?.job.state, "queued")
    }

    func testVerifyingJobWithIntentIsNotBlindlyRequeued() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-recovery-verify-\(UUID().uuidString)", isDirectory: true)
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
        let bytes = Data(repeating: 0xFE, count: 12)
        try bytes.write(to: downloads.appendingPathComponent("file.bin.partial"))
        _ = try FinalizationIntentRepository.beginVerification(
            database: database,
            jobID: jobID,
            finalFilename: "file.bin",
            partialFilename: "file.bin.partial",
            expectedByteSize: Int64(bytes.count),
            expectedChecksum: nil,
            zipAutoExtract: false
        )

        let requeued = try JobRepository.requeueInterruptedTransfers(database: database)
        XCTAssertTrue(requeued.isEmpty)

        let outcomes = try FinalizationIntentRepository.reconcileInterruptedFinalizations(
            database: database
        )
        XCTAssertEqual(outcomes, [
            FinalizationRecoveryOutcome(jobID: jobID, action: .needsResumePromotion)
        ])
    }
}
