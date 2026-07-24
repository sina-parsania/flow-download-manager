// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// User-controlled per-host transfer overrides (distinct from expiring
/// ``HostObservationRepository`` hints). Job-level settings still win.
public enum HostSettingRepository {
    public struct Setting: Sendable, Equatable {
        public var host: String
        public var maxConnections: Int?
        public var maxBytesPerSecond: Int64?
        public var userAgent: String?
        public var credentialProfileID: String?
        public var updatedAt: Date

        public init(
            host: String,
            maxConnections: Int? = nil,
            maxBytesPerSecond: Int64? = nil,
            userAgent: String? = nil,
            credentialProfileID: String? = nil,
            updatedAt: Date = Date()
        ) {
            self.host = host
            self.maxConnections = maxConnections
            self.maxBytesPerSecond = maxBytesPerSecond
            self.userAgent = userAgent
            self.credentialProfileID = credentialProfileID
            self.updatedAt = updatedAt
        }
    }

    /// Lowercase hostname key. Accepts a bare host or a full URL; rejects empty /
    /// path-like input so callers cannot store junk rows.
    public static func normalizeHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host.lowercased()
        }
        if let url = URL(string: "https://\(trimmed)"), let host = url.host, !host.isEmpty,
           !trimmed.contains("/"), !trimmed.contains(" ") {
            return host.lowercased()
        }
        return nil
    }

    public static func list(database: EngineDatabase) throws -> [Setting] {
        try database.pool.read { db in
            try HostSettingRecord
                .order(Column("host"))
                .fetchAll(db)
                .map(setting(from:))
        }
    }

    public static func get(database: EngineDatabase, host: String) throws -> Setting? {
        guard let key = normalizeHost(host) else { return nil }
        return try database.pool.read { db in
            try HostSettingRecord.fetchOne(db, key: key).map(setting(from:))
        }
    }

    /// Upsert by normalized host. Passing all-nil optional fields is allowed —
    /// it still records the host so the user can fill values later — but at
    /// least one override should usually be present; the UI enforces that.
    public static func upsert(database: EngineDatabase, setting: Setting) throws -> Setting {
        guard let host = normalizeHost(setting.host) else {
            throw HostSettingRepositoryError.invalidHost
        }
        if let connections = setting.maxConnections, !(1 ... 32).contains(connections) {
            throw HostSettingRepositoryError.invalidMaxConnections
        }
        if let rate = setting.maxBytesPerSecond, rate <= 0 {
            throw HostSettingRepositoryError.invalidMaxBytesPerSecond
        }
        if let agent = setting.userAgent {
            let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= 512, !trimmed.contains("\n"), !trimmed.contains("\r") else {
                throw HostSettingRepositoryError.invalidUserAgent
            }
        }
        if let credentialID = setting.credentialProfileID {
            guard UUID(uuidString: credentialID) != nil else {
                throw HostSettingRepositoryError.invalidCredentialProfileID
            }
            let exists = try database.pool.read { db in
                try CredentialProfileRecord.fetchOne(db, key: credentialID) != nil
            }
            guard exists else {
                throw HostSettingRepositoryError.unknownCredentialProfileID
            }
        }

        let stored = Setting(
            host: host,
            maxConnections: setting.maxConnections,
            maxBytesPerSecond: setting.maxBytesPerSecond,
            userAgent: setting.userAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            credentialProfileID: setting.credentialProfileID,
            updatedAt: Date()
        )
        try database.pool.write { db in
            try HostSettingRecord(
                host: stored.host,
                maxConnections: stored.maxConnections,
                maxBytesPerSecond: stored.maxBytesPerSecond,
                userAgent: stored.userAgent,
                credentialProfileID: stored.credentialProfileID,
                updatedAt: stored.updatedAt
            ).save(db)
        }
        return stored
    }

    public static func delete(database: EngineDatabase, host: String) throws -> Bool {
        guard let key = normalizeHost(host) else {
            throw HostSettingRepositoryError.invalidHost
        }
        return try database.pool.write { db in
            try HostSettingRecord.deleteOne(db, key: key)
        }
    }

    private static func setting(from record: HostSettingRecord) -> Setting {
        Setting(
            host: record.host,
            maxConnections: record.maxConnections,
            maxBytesPerSecond: record.maxBytesPerSecond,
            userAgent: record.userAgent,
            credentialProfileID: record.credentialProfileID,
            updatedAt: record.updatedAt
        )
    }
}

public enum HostSettingRepositoryError: Error, Equatable, Sendable {
    case invalidHost
    case invalidMaxConnections
    case invalidMaxBytesPerSecond
    case invalidUserAgent
    case invalidCredentialProfileID
    case unknownCredentialProfileID
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
