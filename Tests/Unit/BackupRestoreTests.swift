// SPDX-License-Identifier: GPL-3.0-or-later

import Persistence
import XCTest

/// Backup / restore and integrity of the produced copy
/// (`04-domain-and-data-contracts.md` §13, `08-validation-commands.md` §10).
final class BackupRestoreTests: XCTestCase {
    func testBackupProducesIntegralCopyWithData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("engine.sqlite")
        let backupURL = root.appendingPathComponent("backup/engine-backup.sqlite")

        let source = try EngineDatabase(url: sourceURL)
        _ = try source.seedFixtureJob()
        try source.checkpoint()

        try source.backup(to: backupURL)

        // Open the backup independently and verify integrity + data survived.
        let restored = try EngineDatabase(url: backupURL)
        XCTAssertTrue(try restored.integrityCheck())
        XCTAssertEqual(try restored.count(JobRecord.self), 1)
        XCTAssertTrue(try restored.isAtCurrentSchemaVersion())
    }

    func testBackupOverwritesExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-backup2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("engine.sqlite")
        let backupURL = root.appendingPathComponent("engine-backup.sqlite")

        let source = try EngineDatabase(url: sourceURL)
        _ = try source.seedFixtureJob()
        try source.backup(to: backupURL)
        // Second backup over the same path must succeed (idempotent overwrite).
        XCTAssertNoThrow(try source.backup(to: backupURL))
    }
}
