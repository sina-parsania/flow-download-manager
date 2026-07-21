// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// GRDB-free access surface over the agent's writable database. Callers (the agent
/// and its tests/previews) use these without importing GRDB. The app never links
/// this module — it reads through XPC read models (`02-architecture.md` §9).
public extension EngineDatabase {
    /// Insert a record. Throws on constraint violation (FK/CHECK/unique), which is
    /// how persistence-layer invariants are enforced.
    func insert(_ record: some PersistableRecord & Sendable) throws {
        try pool.write { db in try record.insert(db) }
    }

    /// Row count for a table-backed record type.
    func count<R: TableRecord>(_ type: R.Type) throws -> Int {
        try pool.read { db in try R.fetchCount(db) }
    }

    /// Names of user tables in the current schema (excludes SQLite/GRDB internals).
    func tableNames() throws -> Set<String> {
        try pool.read { db in
            let names = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """)
            return Set(names)
        }
    }

    /// Insert the deterministic fixture graph; returns the job id (tests/previews).
    @discardableResult
    func seedFixtureJob() throws -> String {
        try pool.write { db in try DatabaseSeed.insertFixtureJob(db) }
    }

    /// Whether foreign-key enforcement is active on a fresh connection.
    func foreignKeysEnabled() throws -> Bool {
        try pool.read { db in
            try (Int.fetchOne(db, sql: "PRAGMA foreign_keys")) == 1
        }
    }

    /// The active journal mode (expected `wal` for a `DatabasePool`).
    func journalMode() throws -> String {
        try pool.read { db in
            try (String.fetchOne(db, sql: "PRAGMA journal_mode")) ?? "unknown"
        }
    }
}
