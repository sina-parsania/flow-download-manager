// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Integrity, checkpoint and backup operations on the engine database
/// (`02-architecture.md` §9, `04-domain-and-data-contracts.md` §13). A verified
/// backup precedes any destructive transformation; corruption enters recovery
/// rather than silently recreating history.
public extension EngineDatabase {
    enum MaintenanceError: Error, Equatable {
        case integrityCheckFailed(String)
    }

    /// `PRAGMA integrity_check`; returns `true` only for a fully consistent database.
    func integrityCheck() throws -> Bool {
        try pool.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            return result == "ok"
        }
    }

    /// Throwing variant that surfaces the first reported problem.
    func verifyIntegrity() throws {
        let problem: String? = try pool.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            return result == "ok" ? nil : (result ?? "unknown")
        }
        if let problem { throw MaintenanceError.integrityCheckFailed(problem) }
    }

    /// Truncating WAL checkpoint, folding the log back into the main file.
    func checkpoint() throws {
        try pool.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
        }
    }

    /// Produce a consistent point-in-time copy at `destinationURL` using SQLite's
    /// online backup API (via GRDB), suitable as the pre-migration backup.
    func backup(to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        let destination = try DatabaseQueue(path: destinationURL.path)
        try pool.backup(to: destination)
    }
}
