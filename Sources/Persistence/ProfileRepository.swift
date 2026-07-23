// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import SharedSecurity

/// Non-secret credential profile metadata stored as JSON in `credential_profiles.metadata`.
public struct CredentialProfileMetadata: Codable, Sendable, Equatable {
    public var displayName: String
    public var username: String
    public var hostHint: String?

    public init(displayName: String, username: String, hostHint: String? = nil) {
        self.displayName = displayName
        self.username = username
        self.hostHint = hostHint
    }
}

/// Non-secret proxy profile metadata stored as JSON in `proxy_profiles.metadata`.
public struct ProxyProfileMetadata: Codable, Sendable, Equatable {
    public var displayName: String
    public var kind: String
    public var host: String
    public var port: Int

    public init(displayName: String, kind: String, host: String, port: Int) {
        self.displayName = displayName
        self.kind = kind
        self.host = host
        self.port = port
    }

    public var proxyURL: String {
        "\(kind)://\(host):\(port)"
    }
}

public struct CredentialProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "credential_profiles"
    public var id: String
    public var metadata: String
    public var keychainPersistentReference: Data

    public init(id: String, metadata: String, keychainPersistentReference: Data) {
        self.id = id
        self.metadata = metadata
        self.keychainPersistentReference = keychainPersistentReference
    }
}

public struct ProxyProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "proxy_profiles"
    public var id: String
    public var metadata: String
    public var keychainPersistentReference: Data?

    public init(id: String, metadata: String, keychainPersistentReference: Data?) {
        self.id = id
        self.metadata = metadata
        self.keychainPersistentReference = keychainPersistentReference
    }
}

public struct ScheduleRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "schedules"
    public var id: String
    public var recurrence: String
    public var timeZonePolicy: String
    public var missedOccurrencePolicy: String
    public var constraints: String?

    public init(
        id: String,
        recurrence: String,
        timeZonePolicy: String,
        missedOccurrencePolicy: String,
        constraints: String?
    ) {
        self.id = id
        self.recurrence = recurrence
        self.timeZonePolicy = timeZonePolicy
        self.missedOccurrencePolicy = missedOccurrencePolicy
        self.constraints = constraints
    }
}

/// Agent-only profile and schedule helpers (FR-TRN-003/004, FR-QUE-002).
public enum ProfileRepository {
    public static func upsertCredentialProfile(
        database: EngineDatabase,
        id: String,
        metadata: CredentialProfileMetadata,
        passwordUTF8: Data,
        secretStore: any SecretStore
    ) throws {
        let encoder = JSONEncoder()
        let metaData = try encoder.encode(metadata)
        guard let metaString = String(data: metaData, encoding: .utf8) else {
            throw ProfileRepositoryError.encodingFailed
        }
        let ref = try secretStore.store(passwordUTF8, account: "credential.\(id)")
        try database.pool.write { db in
            try CredentialProfileRecord(
                id: id,
                metadata: metaString,
                keychainPersistentReference: ref
            ).save(db)
        }
    }

    public static func loadUserpwd(
        database: EngineDatabase,
        profileID: String,
        secretStore: any SecretStore
    ) throws -> String {
        let record = try database.pool.read { db in
            try CredentialProfileRecord.fetchOne(db, key: profileID)
        }
        guard let record else { throw ProfileRepositoryError.notFound(profileID) }
        let meta = try JSONDecoder().decode(
            CredentialProfileMetadata.self,
            from: Data(record.metadata.utf8)
        )
        let passwordData = try secretStore.readSecret(persistentRef: record.keychainPersistentReference)
        let password = String(data: passwordData, encoding: .utf8) ?? ""
        return "\(meta.username):\(password)"
    }

    public static func upsertProxyProfile(
        database: EngineDatabase,
        id: String,
        metadata: ProxyProfileMetadata
    ) throws {
        let encoder = JSONEncoder()
        let metaData = try encoder.encode(metadata)
        guard let metaString = String(data: metaData, encoding: .utf8) else {
            throw ProfileRepositoryError.encodingFailed
        }
        try database.pool.write { db in
            try ProxyProfileRecord(
                id: id,
                metadata: metaString,
                keychainPersistentReference: nil
            ).save(db)
        }
    }

    public static func loadProxyURL(database: EngineDatabase, profileID: String) throws -> String {
        let record = try database.pool.read { db in
            try ProxyProfileRecord.fetchOne(db, key: profileID)
        }
        guard let record else { throw ProfileRepositoryError.notFound(profileID) }
        let meta = try JSONDecoder().decode(
            ProxyProfileMetadata.self,
            from: Data(record.metadata.utf8)
        )
        return meta.proxyURL
    }

    /// One-shot schedule: `constraints` holds ISO-8601 `startAt` instant.
    public static func createOneShotSchedule(
        database: EngineDatabase,
        id: String,
        startAt: Date
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload = "{\"startAt\":\"\(formatter.string(from: startAt))\"}"
        try database.pool.write { db in
            try ScheduleRecord(
                id: id,
                recurrence: "once",
                timeZonePolicy: "utc",
                missedOccurrencePolicy: "runImmediately",
                constraints: payload
            ).insert(db)
        }
    }

    /// Promote due `scheduled` jobs to `queued`. Returns promoted job IDs.
    public static func promoteDueScheduledJobs(
        database: EngineDatabase,
        now: Date = Date()
    ) throws -> [String] {
        try database.pool.write { db in
            let jobs = try JobRecord
                .filter(Column("state") == "scheduled")
                .fetchAll(db)
            var promoted: [String] = []
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            for var job in jobs {
                guard let scheduleID = job.scheduleID,
                      let schedule = try ScheduleRecord.fetchOne(db, key: scheduleID),
                      let constraints = schedule.constraints,
                      let data = constraints.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let startAtString = json["startAt"] as? String,
                      let startAt = formatter.date(from: startAtString),
                      startAt <= now
                else { continue }
                job.state = "queued"
                job.updatedAt = now
                job.revision += 1
                try job.update(db)
                promoted.append(job.id)
            }
            return promoted
        }
    }
}

public enum ProfileRepositoryError: Error, Equatable, Sendable {
    case encodingFailed
    case notFound(String)
}
