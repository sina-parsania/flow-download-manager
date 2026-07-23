// SPDX-License-Identifier: GPL-3.0-or-later

import GRDB
import Persistence
import XCTest

/// Migration v1→v2 round-trip and interrupted-migration atomicity
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
            "cookie_profiles", "schedules", "post_processing_pipelines", "host_observations"
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

    func testV1ToV2MigrationRoundTripPreservesJobs() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let v1 = try EngineDatabase(url: url, migrator: SchemaMigrator.v1Only)
        let jobID = "00000000-0000-7000-8000-000000000001"
        let profileID = "00000000-0000-7000-8000-0000000000d1"
        let categoryID = "00000000-0000-7000-8000-0000000000c1"
        let resourceID = "00000000-0000-7000-8000-0000000000a1"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // Seed with raw SQL so JobRecord's v2 columns are not referenced on a v1 schema.
        try v1.pool.write { db in
            try DestinationProfileRecord(
                id: profileID, name: "Downloads",
                bookmarkData: Data([0x00]), volumeIdentity: nil, conflictPolicy: "rename"
            ).insert(db)
            try CategoryRecord(
                id: categoryID, stableKey: "documents", displayNameKey: "category.documents",
                systemSymbol: "doc", destinationProfileID: profileID
            ).insert(db)
            try ResourceRecord(
                id: resourceID, originalURL: "https://example.test/file.bin",
                canonicalURL: "https://example.test/file.bin", finalURL: nil,
                protocolKind: "https", filenameEvidence: "file.bin",
                mimeEvidence: "application/octet-stream",
                expectedSize: 1024, strongETag: nil, lastModified: nil, checksum: nil,
                identityRevision: 1
            ).insert(db)
            try db.execute(
                sql: """
                INSERT INTO jobs (
                    id, batchID, resourceID, state, priority, queuePosition,
                    categoryID, projectID, destinationProfileID, scheduleID,
                    createdAt, updatedAt, revision, terminalReason
                ) VALUES (?, NULL, ?, 'queued', 0, 0, ?, NULL, ?, NULL, ?, ?, 1, NULL)
                """,
                arguments: [jobID, resourceID, categoryID, profileID, now, now]
            )
        }
        XCTAssertFalse(try v1.tableNames().contains("cookie_profiles"))

        let v2 = try EngineDatabase(url: url, migrator: SchemaMigrator.current)
        XCTAssertTrue(try v2.isAtCurrentSchemaVersion())
        XCTAssertTrue(try v2.tableNames().contains("cookie_profiles"))
        XCTAssertEqual(try v2.count(JobRecord.self), 1)

        let job = try v2.pool.read { db in
            try JobRecord.fetchOne(db, key: jobID)
        }
        XCTAssertEqual(job?.id, jobID)
        XCTAssertNil(job?.credentialProfileID)
        XCTAssertNil(job?.proxyProfileID)
        XCTAssertNil(job?.cookieProfileID)
        XCTAssertNil(job?.customHeadersJSON)

        try v2.pool.read { db in
            let names = try Row.fetchAll(db, sql: "PRAGMA table_info(jobs)").map { row -> String in
                row["name"]
            }
            XCTAssertTrue(names.contains("credentialProfileID"))
            XCTAssertTrue(names.contains("proxyProfileID"))
            XCTAssertTrue(names.contains("cookieProfileID"))
            XCTAssertTrue(names.contains("customHeadersJSON"))
        }
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
