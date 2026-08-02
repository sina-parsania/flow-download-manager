// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Expiring per-host transfer hints (never treated as proof).
public enum HostObservationRepository {
    public struct Observation: Codable, Sendable, Equatable {
        public var maxSegments: Int?
        public var rangeOK: Bool?
        /// Connection count the ramp settled on last time, used as the **starting
        /// point** for the next download from this host.
        ///
        /// Safe to keep per host with no size band, unlike ``maxSegments``. That
        /// one is a hard cap, so a small file's answer really would poison a large
        /// follow-up. This is only where the ramp begins, and everything
        /// downstream still applies the size rule: `preferredSegmentCount` caps by
        /// content length, and that cap binds before the ramp's target does. A
        /// 5 MB file inheriting 20 from an 800 MB one still runs as a 5 MB file.
        ///
        /// Worth having because the ramp needs 30-40 s to climb, which a queue of
        /// episodes from one site would otherwise pay again on every single item.
        public var settledConnections: Int?

        public init(
            maxSegments: Int? = nil,
            rangeOK: Bool? = nil,
            settledConnections: Int? = nil
        ) {
            self.maxSegments = maxSegments
            self.rangeOK = rangeOK
            self.settledConnections = settledConnections
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
