// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import GRDB

/// GRDB migrations for the engine database.
///
/// Phase 0 ships migration `v1` covering the Phase 0/1 foundational tables
/// (`04-domain-and-data-contracts.md` §7). Media/torrent tables are added only in
/// their phase via a later versioned migration. `eraseDatabaseOnSchemaChange`
/// stays off: no migration silently discards user history (`13. Migration
/// contract`); downgrade uses a restored pre-upgrade backup.
public enum SchemaMigrator {
    /// The migrator carrying every registered migration up to the current version.
    public static var current: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = false
        registerV1(&migrator)
        return migrator
    }

    /// Stable identifier for the v1 migration.
    ///
    /// The contract's §7 `schema_migrations` bookkeeping table is provided by GRDB
    /// itself as `grdb_migrations` (which records applied migration identifiers);
    /// this migrator does not create a separate table for it.
    public static let v1Identifier = "v1-foundation"

    private static func registerV1(_ migrator: inout DatabaseMigrator) {
        // CHECK domains sourced from the Domain enums so DB and code cannot drift.
        // GRDB builds `col IN (…)` from `[SQLExpressible].contains(Column)`.
        let jobStates = JobState.allCases.map(\.rawValue)
        let segmentStates = SegmentState.allCases.map(\.rawValue)
        let terminalReasons = TerminalReason.allCases.map(\.rawValue)

        migrator.registerMigration(v1Identifier) { db in
            // --- Metadata / lookup tables (referenced by jobs) ---

            try db.create(table: "batches") { t in
                t.primaryKey("id", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("source", .text).notNull()
                t.column("originalItemCount", .integer).notNull().check { $0 >= 0 }
                t.column("displayName", .text)
            }

            try db.create(table: "resources") { t in
                t.primaryKey("id", .text)
                t.column("originalURL", .text).notNull()
                t.column("canonicalURL", .text).notNull()
                t.column("finalURL", .text)
                t.column("protocolKind", .text).notNull()
                t.column("filenameEvidence", .text)
                t.column("mimeEvidence", .text)
                t.column("expectedSize", .integer).check { $0 == nil || $0 >= 0 }
                t.column("strongETag", .text)
                t.column("lastModified", .datetime)
                t.column("checksum", .text)
                t.column("identityRevision", .integer).notNull().defaults(to: 1)
            }

            try db.create(table: "destination_profiles") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                // Security-scoped bookmark blob — a reference, not a secret.
                t.column("bookmarkData", .blob).notNull()
                t.column("volumeIdentity", .text)
                t.column("conflictPolicy", .text).notNull()
            }

            try db.create(table: "categories") { t in
                t.primaryKey("id", .text)
                t.column("stableKey", .text).notNull().unique()
                t.column("displayNameKey", .text).notNull()
                t.column("systemSymbol", .text).notNull()
                t.column("destinationProfileID", .text)
                    .references("destination_profiles", onDelete: .setNull)
            }

            try db.create(table: "category_rules") { t in
                t.primaryKey("id", .text)
                t.column("priority", .integer).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("predicate", .text).notNull()
                t.column("action", .text).notNull()
                t.column("createdByUser", .boolean).notNull().defaults(to: true)
                t.column("revision", .integer).notNull().defaults(to: 1)
            }

            try db.create(table: "projects") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("colorRole", .text)
                t.column("defaultDestinationProfileID", .text)
                    .references("destination_profiles", onDelete: .setNull)
            }

            try db.create(table: "tags") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                // Case-fold/normalization key enforces unique tag name under the
                // documented Unicode policy (`§7`); populated by the repository.
                t.column("nameFold", .text).notNull().unique()
            }

            try db.create(table: "credential_profiles") { t in
                t.primaryKey("id", .text)
                t.column("metadata", .text).notNull() // nonsecret metadata only
                // Opaque Keychain reference; the secret itself never enters SQLite.
                t.column("keychainPersistentReference", .blob).notNull()
            }

            try db.create(table: "proxy_profiles") { t in
                t.primaryKey("id", .text)
                t.column("metadata", .text).notNull()
                t.column("keychainPersistentReference", .blob)
            }

            try db.create(table: "schedules") { t in
                t.primaryKey("id", .text)
                t.column("recurrence", .text).notNull()
                t.column("timeZonePolicy", .text).notNull()
                t.column("missedOccurrencePolicy", .text).notNull()
                t.column("constraints", .text)
            }

            try db.create(table: "post_processing_pipelines") { t in
                t.primaryKey("id", .text)
                t.column("steps", .text).notNull() // ordered typed steps (JSON)
                t.column("failurePolicy", .text).notNull()
            }

            try db.create(table: "host_observations") { t in
                // Expiring hints, never proof (`02-architecture.md` §7.2).
                t.primaryKey("host", .text)
                t.column("observation", .text).notNull()
                t.column("expiresAt", .datetime).notNull()
            }

            // --- Jobs and their children ---

            try db.create(table: "jobs") { t in
                t.primaryKey("id", .text)
                t.column("batchID", .text).references("batches", onDelete: .setNull)
                // Deleting metadata must not orphan a job's resource identity.
                t.column("resourceID", .text).notNull()
                    .references("resources", onDelete: .restrict)
                t.column("state", .text).notNull().check { jobStates.contains($0) }
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("queuePosition", .integer).notNull().defaults(to: 0)
                // Exactly one category per job (`§7`).
                t.column("categoryID", .text).notNull()
                    .references("categories", onDelete: .restrict)
                t.column("projectID", .text).references("projects", onDelete: .setNull)
                t.column("destinationProfileID", .text).notNull()
                    .references("destination_profiles", onDelete: .restrict)
                t.column("scheduleID", .text).references("schedules", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("revision", .integer).notNull().defaults(to: 1)
                t.column("terminalReason", .text).check { $0 == nil || terminalReasons.contains($0) }
                // Terminal failed/cancelled states require a terminal reason;
                // completed carries none but always has updatedAt (`§3`, `§7`).
                t.check(sql: "state NOT IN ('failed','cancelled') OR terminalReason IS NOT NULL")
            }
            try db.create(index: "idx_jobs_state", on: "jobs", columns: ["state"])
            try db.create(index: "idx_jobs_batch", on: "jobs", columns: ["batchID"])
            try db.create(index: "idx_jobs_category", on: "jobs", columns: ["categoryID"])

            try db.create(table: "attempts") { t in
                t.primaryKey("id", .text)
                t.column("jobID", .text).notNull().references("jobs", onDelete: .cascade)
                t.column("ordinal", .integer).notNull().check { $0 >= 0 }
                t.column("startedAt", .datetime)
                t.column("endedAt", .datetime)
                t.column("outcome", .text)
                t.column("transferredBytes", .integer).notNull().defaults(to: 0).check { $0 >= 0 }
                t.column("retryCount", .integer).notNull().defaults(to: 0).check { $0 >= 0 }
                t.column("dependencyVersions", .text)
                t.column("sanitizedError", .text)
                t.uniqueKey(["jobID", "ordinal"])
            }
            try db.create(index: "idx_attempts_job", on: "attempts", columns: ["jobID"])

            try db.create(table: "segments") { t in
                t.primaryKey("id", .text)
                t.column("attemptID", .text).notNull().references("attempts", onDelete: .cascade)
                t.column("lowerBound", .integer).notNull().check { $0 >= 0 }
                t.column("upperBoundExclusive", .integer).notNull()
                t.column("committedExclusive", .integer).notNull()
                t.column("state", .text).notNull().check { segmentStates.contains($0) }
                t.column("retryCount", .integer).notNull().defaults(to: 0).check { $0 >= 0 }
                t.column("rollingThroughput", .double).notNull().defaults(to: 0)
                // lowerBound <= committedExclusive <= upperBoundExclusive (`§4`).
                t.check(sql: "lowerBound <= committedExclusive AND committedExclusive <= upperBoundExclusive")
            }
            try db.create(index: "idx_segments_attempt", on: "segments", columns: ["attemptID"])

            try db.create(table: "job_tags") { t in
                t.column("jobID", .text).notNull().references("jobs", onDelete: .cascade)
                t.column("tagID", .text).notNull().references("tags", onDelete: .cascade)
                t.primaryKey(["jobID", "tagID"])
            }

            try db.create(table: "events") { t in
                // Append-only recovery journal; ordered by autoincrement sequence.
                t.autoIncrementedPrimaryKey("sequence")
                t.column("jobID", .text).references("jobs", onDelete: .setNull)
                t.column("occurredAt", .datetime).notNull()
                t.column("type", .text).notNull()
                t.column("sanitizedPayload", .text)
            }
            try db.create(index: "idx_events_job", on: "events", columns: ["jobID"])
        }
    }
}
