// SPDX-License-Identifier: GPL-3.0-or-later

import Persistence
import XCTest

/// Database recovery across an unclean close / injected boundary
/// (`05-quality-testing-release-gates.md` §4 Process/persistence,
/// `08-validation-commands.md` §10 recovery-crash-matrix). The filesystem is not
/// blindly trusted: reopening reconciles the WAL.
final class DatabaseRecoveryTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-recovery-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("engine.sqlite")
    }

    func testReopenAfterUncleanCloseRecoversCommittedData() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Write committed data, then drop the reference WITHOUT checkpointing —
        // simulating a process exit that leaves committed frames in the WAL.
        do {
            let db = try EngineDatabase(url: url)
            _ = try db.seedFixtureJob()
        }

        // Reopening must recover the committed rows and pass integrity.
        let reopened = try EngineDatabase(url: url)
        XCTAssertEqual(try reopened.count(JobRecord.self), 1)
        XCTAssertTrue(try reopened.integrityCheck())
        XCTAssertTrue(try reopened.isAtCurrentSchemaVersion())
    }

    func testCheckpointFoldsWALAndPreservesData() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let db = try EngineDatabase(url: url)
        _ = try db.seedFixtureJob()
        try db.checkpoint()
        XCTAssertEqual(try db.count(JobRecord.self), 1)
        XCTAssertTrue(try db.integrityCheck())
    }

    func testRestoredBackupOpensAndPreservesData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-recovery-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("engine.sqlite")
        let backupURL = root.appendingPathComponent("engine-backup.sqlite")

        let source = try EngineDatabase(url: sourceURL)
        _ = try source.seedFixtureJob()
        try source.backup(to: backupURL)

        // Simulate downgrade/restore: open the backup as the live database.
        let restored = try EngineDatabase(url: backupURL)
        XCTAssertEqual(try restored.count(JobRecord.self), 1)
        XCTAssertTrue(try restored.integrityCheck())
    }
}
