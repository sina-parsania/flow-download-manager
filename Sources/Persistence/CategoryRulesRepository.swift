// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// CRUD for user category rules. No rules are seeded by default (FR-CAT).
public enum CategoryRulesRepository {
    public static func list(
        database: EngineDatabase
    ) throws -> [CategoryRuleRecord] {
        try database.pool.read { db in
            try CategoryRuleRecord
                .order(Column("priority").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    public static func upsert(
        database: EngineDatabase,
        id: String,
        priority: Int,
        enabled: Bool = true,
        predicateJSON: String,
        categoryStableKey: String,
        createdByUser: Bool = true
    ) throws {
        let trimmedKey = categoryStableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, trimmedKey.utf8.count <= 64 else {
            throw CategoryRulesRepositoryError.invalidCategory
        }
        guard predicateJSON.utf8.count > 0, predicateJSON.utf8.count <= 4096 else {
            throw CategoryRulesRepositoryError.invalidPredicate
        }
        guard try JSONSerialization.jsonObject(with: Data(predicateJSON.utf8)) is [String: Any] else {
            throw CategoryRulesRepositoryError.invalidPredicate
        }

        try database.pool.write { db in
            guard try CategoryRecord
                .filter(Column("stableKey") == trimmedKey)
                .fetchOne(db) != nil
            else {
                throw CategoryRulesRepositoryError.unknownCategory(trimmedKey)
            }
            let existing = try CategoryRuleRecord.fetchOne(db, key: id)
            let record = CategoryRuleRecord(
                id: id,
                priority: priority,
                enabled: enabled,
                predicate: predicateJSON,
                action: trimmedKey,
                createdByUser: createdByUser,
                revision: (existing?.revision ?? 0) + 1
            )
            try record.save(db)
        }
    }

    public static func delete(database: EngineDatabase, id: String) throws {
        try database.pool.write { db in
            _ = try CategoryRuleRecord.deleteOne(db, key: id)
        }
    }

    /// Next priority slot (max + 1), or 0 when empty.
    public static func nextPriority(database: EngineDatabase) throws -> Int {
        try database.pool.read { db in
            let max = try Int.fetchOne(
                db,
                sql: "SELECT MAX(priority) FROM category_rules"
            ) ?? -1
            return max + 1
        }
    }
}

public enum CategoryRulesRepositoryError: Error, Equatable, Sendable {
    case invalidCategory
    case invalidPredicate
    case unknownCategory(String)
}
