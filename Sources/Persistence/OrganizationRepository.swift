// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Projects and tags (FR-ORG minimal). Agent is the sole writer.
public enum OrganizationRepository {
    public static func createProject(
        database: EngineDatabase,
        id: String = UUID().uuidString.lowercased(),
        name: String,
        colorRole: String? = nil
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else {
            throw OrganizationRepositoryError.invalidName
        }
        try database.pool.write { db in
            try ProjectRecord(
                id: id,
                name: truncated(trimmed, maxUTF8: 256),
                colorRole: colorRole.map { truncated($0, maxUTF8: 64) },
                defaultDestinationProfileID: nil
            ).insert(db)
        }
        return id
    }

    public static func upsertProject(
        database: EngineDatabase,
        id: String,
        name: String,
        colorRole: String? = nil
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else {
            throw OrganizationRepositoryError.invalidName
        }
        try database.pool.write { db in
            let record = ProjectRecord(
                id: id,
                name: truncated(trimmed, maxUTF8: 256),
                colorRole: colorRole.map { truncated($0, maxUTF8: 64) },
                defaultDestinationProfileID: nil
            )
            try record.save(db)
        }
    }

    public static func createTag(
        database: EngineDatabase,
        id: String = UUID().uuidString.lowercased(),
        name: String
    ) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else {
            throw OrganizationRepositoryError.invalidName
        }
        let fold = nameFold(trimmed)
        try database.pool.write { db in
            try TagRecord(
                id: id,
                name: truncated(trimmed, maxUTF8: 256),
                nameFold: fold
            ).insert(db)
        }
        return id
    }

    public static func upsertTag(
        database: EngineDatabase,
        id: String,
        name: String
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256 else {
            throw OrganizationRepositoryError.invalidName
        }
        let fold = nameFold(trimmed)
        try database.pool.write { db in
            let record = TagRecord(
                id: id,
                name: truncated(trimmed, maxUTF8: 256),
                nameFold: fold
            )
            try record.save(db)
        }
    }

    public static func attachTagToJob(
        database: EngineDatabase,
        jobID: String,
        tagID: String
    ) throws {
        try database.pool.write { db in
            guard try JobRecord.fetchOne(db, key: jobID) != nil else {
                throw OrganizationRepositoryError.jobNotFound(jobID)
            }
            guard try TagRecord.fetchOne(db, key: tagID) != nil else {
                throw OrganizationRepositoryError.tagNotFound(tagID)
            }
            if try JobTagRecord.fetchOne(db, key: ["jobID": jobID, "tagID": tagID]) == nil {
                try JobTagRecord(jobID: jobID, tagID: tagID).insert(db)
            }
        }
    }

    public static func setJobTags(
        database: EngineDatabase,
        jobID: String,
        tagIDs: [String]
    ) throws {
        try database.pool.write { db in
            guard try JobRecord.fetchOne(db, key: jobID) != nil else {
                throw OrganizationRepositoryError.jobNotFound(jobID)
            }
            try db.execute(sql: "DELETE FROM job_tags WHERE jobID = ?", arguments: [jobID])
            for tagID in tagIDs {
                guard try TagRecord.fetchOne(db, key: tagID) != nil else {
                    throw OrganizationRepositoryError.tagNotFound(tagID)
                }
                try JobTagRecord(jobID: jobID, tagID: tagID).insert(db)
            }
        }
    }

    public static func setJobProject(
        database: EngineDatabase,
        jobID: String,
        projectID: String?
    ) throws {
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID) else {
                throw OrganizationRepositoryError.jobNotFound(jobID)
            }
            if let projectID {
                guard try ProjectRecord.fetchOne(db, key: projectID) != nil else {
                    throw OrganizationRepositoryError.projectNotFound(projectID)
                }
            }
            job.projectID = projectID
            job.updatedAt = Date()
            job.revision += 1
            try job.update(db)
        }
    }

    public static func listProjects(
        database: EngineDatabase
    ) throws -> [(id: String, name: String, colorRole: String?)] {
        try database.pool.read { db in
            try ProjectRecord
                .order(Column("name").asc)
                .fetchAll(db)
                .map { ($0.id, $0.name, $0.colorRole) }
        }
    }

    public static func listTags(
        database: EngineDatabase
    ) throws -> [(id: String, name: String)] {
        try database.pool.read { db in
            try TagRecord
                .order(Column("name").asc)
                .fetchAll(db)
                .map { ($0.id, $0.name) }
        }
    }

    public static func projectName(
        database: EngineDatabase,
        projectID: String?
    ) throws -> String? {
        guard let projectID else { return nil }
        return try database.pool.read { db in
            try ProjectRecord.fetchOne(db, key: projectID)?.name
        }
    }

    public static func tagNames(
        database: EngineDatabase,
        jobID: String
    ) throws -> [String] {
        try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT t.name FROM tags t
                INNER JOIN job_tags jt ON jt.tagID = t.id
                WHERE jt.jobID = ?
                ORDER BY t.name ASC
                """,
                arguments: [jobID]
            )
        }
    }

    private static func nameFold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func truncated(_ value: String, maxUTF8: Int) -> String {
        guard value.utf8.count > maxUTF8 else { return value }
        var end = value.endIndex
        while value[..<end].utf8.count > maxUTF8 {
            end = value.index(before: end)
        }
        return String(value[..<end])
    }
}

public enum OrganizationRepositoryError: Error, Equatable, Sendable {
    case invalidName
    case jobNotFound(String)
    case tagNotFound(String)
    case projectNotFound(String)
}
