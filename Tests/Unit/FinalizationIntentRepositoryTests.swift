// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import GRDB
import Persistence
import XCTest

final class FinalizationIntentRepositoryTests: XCTestCase {
    private func openTempDatabase() throws -> (EngineDatabase, URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-finalization-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("engine.sqlite")
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(
            database: database,
            defaultDestinationDirectory: downloads
        )
        return (database, root, downloads)
    }

    private func seedDownloadingJob(
        _ database: EngineDatabase,
        filename: String = "artifact.bin"
    ) throws -> String {
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
        return jobID
    }

    func testBeginVerificationPersistsIntentAndStateAtomically() throws {
        let (database, root, _) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let jobID = try seedDownloadingJob(database)
        let revision = try FinalizationIntentRepository.beginVerification(
            database: database,
            jobID: jobID,
            finalFilename: "artifact.bin",
            partialFilename: "artifact.bin.partial",
            expectedByteSize: 42,
            expectedChecksum: nil,
            zipAutoExtract: false
        )
        XCTAssertEqual(revision, 4)

        let intent = try FinalizationIntentRepository.fetchIntent(database: database, jobID: jobID)
        XCTAssertEqual(intent?.stage, FinalizationIntentStage.prepared.rawValue)
        XCTAssertEqual(intent?.expectedByteSize, 42)

        let rows = try JobRepository.fetchJobRows(database: database)
        XCTAssertEqual(rows.first?.job.state, JobState.verifying.rawValue)
    }

    func testReconcileAfterRenameBeforePromotedCommitCompletesWithoutRedownload() throws {
        let (database, root, downloads) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }

        let jobID = try seedDownloadingJob(database)
        _ = try FinalizationIntentRepository.beginVerification(
            database: database,
            jobID: jobID,
            finalFilename: "artifact.bin",
            partialFilename: "artifact.bin.partial",
            expectedByteSize: 5,
            expectedChecksum: nil,
            zipAutoExtract: false
        )

        let final = downloads.appendingPathComponent("artifact.bin")
        try Data("hello".utf8).write(to: final)

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
        XCTAssertNil(try FinalizationIntentRepository.fetchIntent(database: database, jobID: jobID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: downloads.appendingPathComponent("artifact.bin.partial").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
    }
}
