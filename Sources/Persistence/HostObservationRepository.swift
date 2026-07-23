// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Expiring per-host transfer hints (never treated as proof).
public enum HostObservationRepository {
    public struct Observation: Codable, Sendable, Equatable {
        public var maxSegments: Int?
        public var rangeOK: Bool?

        public init(maxSegments: Int? = nil, rangeOK: Bool? = nil) {
            self.maxSegments = maxSegments
            self.rangeOK = rangeOK
        }
    }

    /// Returns a non-expired observation for `host`, or nil.
    public static func get(
        database: EngineDatabase,
        host: String,
        now: Date = Date()
    ) throws -> Observation? {
        try database.pool.read { db in
            guard let record = try HostObservationRecord.fetchOne(db, key: host),
                  record.expiresAt > now
            else { return nil }
            return try JSONDecoder().decode(
                Observation.self,
                from: Data(record.observation.utf8)
            )
        }
    }

    /// Upserts a JSON observation with an absolute expiry.
    public static func set(
        database: EngineDatabase,
        host: String,
        observation: Observation,
        expiresAt: Date
    ) throws {
        let data = try JSONEncoder().encode(observation)
        guard let json = String(data: data, encoding: .utf8) else {
            throw HostObservationRepositoryError.encodingFailed
        }
        try database.pool.write { db in
            try HostObservationRecord(
                host: host,
                observation: json,
                expiresAt: expiresAt
            ).save(db)
        }
    }
}

public enum HostObservationRepositoryError: Error, Equatable, Sendable {
    case encodingFailed
}
