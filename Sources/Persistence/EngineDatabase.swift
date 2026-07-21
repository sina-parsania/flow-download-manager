// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Owns the engine's writable database connection.
///
/// Backed by a GRDB `DatabasePool` (WAL, concurrent readers, single writer). Only
/// the agent constructs this; the app reads through XPC read models
/// (`02-architecture.md` §9). GRDB's `DatabasePool` is internally thread-safe, so
/// this wrapper is `@unchecked Sendable`.
public final class EngineDatabase: @unchecked Sendable {
    public let pool: DatabasePool

    /// Open (creating parent directories as needed) at `url`, applying the schema
    /// migrator to bring the database to the current version.
    public init(url: URL, migrator: DatabaseMigrator = SchemaMigrator.current) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        pool = try DatabasePool(path: url.path, configuration: DatabaseConfiguration.make())
        try migrator.migrate(pool)
    }

    /// Whether the schema has reached the current target version.
    public func isAtCurrentSchemaVersion() throws -> Bool {
        try pool.read { db in try SchemaMigrator.current.hasCompletedMigrations(db) }
    }

    /// Default on-disk location under Application Support for the given agent
    /// identifier.
    public static func defaultURL(agentIdentifier: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return base
            .appendingPathComponent(agentIdentifier, isDirectory: true)
            .appendingPathComponent("engine.sqlite", isDirectory: false)
    }
}
