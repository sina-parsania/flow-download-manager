// SPDX-License-Identifier: GPL-3.0-or-later

import GRDB
import Persistence
import XCTest

/// Migration v1 round-trip and interrupted-migration atomicity
/// (`04-domain-and-data-contracts.md` §13, `08-validation-commands.md` §10).
final class MigrationTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-migtest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("engine.sqlite")
    }

    func testMigrateFromEmptyCreatesAllTables() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let db = try EngineDatabase(url: url)
        let tables = try db.tableNames()

        let expected: Set<String> = [
            "batches", "resources", "jobs", "attempts", "segments", "events",
            "categories", "category_rules", "projects", "tags", "job_tags",
            "destination_profiles", "credential_profiles", "proxy_profiles",
            "schedules", "post_processing_pipelines", "host_observations"
        ]
        XCTAssertTrue(expected.isSubset(of: tables), "missing: \(expected.subtracting(tables))")
        XCTAssertTrue(try db.isAtCurrentSchemaVersion())
    }

    func testWALAndForeignKeysConfigured() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try EngineDatabase(url: url)
        XCTAssertEqual(try db.journalMode().lowercased(), "wal")
        XCTAssertTrue(try db.foreignKeysEnabled())
    }

    func testReopenIsIdempotent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try EngineDatabase(url: url)
        _ = try first.seedFixtureJob()
        XCTAssertEqual(try first.count(JobRecord.self), 1)

        // Re-open the same file: migration must be a no-op and data must persist.
        let second = try EngineDatabase(url: url)
        XCTAssertTrue(try second.isAtCurrentSchemaVersion())
        XCTAssertEqual(try second.count(JobRecord.self), 1)
    }

    func testInterruptedMigrationRollsBack() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // A migrator whose single migration creates a table and then throws. GRDB
        // runs each migration in a transaction, so the failure must roll the whole
        // migration back, leaving no tables.
        struct InjectedFailure: Error {}
        var failing = DatabaseMigrator()
        failing.registerMigration("v1-foundation") { db in
            try db.create(table: "batches") { $0.primaryKey("id", .text) }
            throw InjectedFailure()
        }

        XCTAssertThrowsError(try EngineDatabase(url: url, migrator: failing))

        // Re-open with the real migrator: the DB must be clean and migrate fully.
        let recovered = try EngineDatabase(url: url)
        XCTAssertTrue(try recovered.tableNames().contains("jobs"))
        XCTAssertTrue(try recovered.isAtCurrentSchemaVersion())
    }
}
