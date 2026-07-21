// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A phantom-typed entity identifier. Prevents assigning e.g. a `ResourceID`
/// where a `JobID` is expected. Backed by a UUIDv7 created at the authority that
/// owns creation (`04-domain-and-data-contracts.md` §1).
public struct EntityID<Entity>: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Mint a fresh, time-ordered identifier.
    public static func generate() -> EntityID<Entity> {
        EntityID(UUIDv7.generate())
    }
}

public enum BatchEntity {}
public enum JobEntity {}
public enum ResourceEntity {}
public enum AttemptEntity {}
public enum SegmentEntity {}
public enum CategoryEntity {}
public enum ProjectEntity {}
public enum TagEntity {}
public enum DestinationProfileEntity {}

public typealias BatchID = EntityID<BatchEntity>
public typealias JobID = EntityID<JobEntity>
public typealias ResourceID = EntityID<ResourceEntity>
public typealias AttemptID = EntityID<AttemptEntity>
public typealias SegmentID = EntityID<SegmentEntity>
public typealias CategoryID = EntityID<CategoryEntity>
public typealias ProjectID = EntityID<ProjectEntity>
public typealias TagID = EntityID<TagEntity>
public typealias DestinationProfileID = EntityID<DestinationProfileEntity>

/// Minimal UUIDv7 (time-ordered) generator (RFC 9562 §5.7): 48-bit Unix
/// milliseconds, 4-bit version `0b0111`, 2-bit variant `0b10`, remaining bits
/// random. Time-ordering makes primary keys index-friendly and makes recent rows
/// sort last without a separate timestamp.
public enum UUIDv7 {
    public static func generate() -> UUID {
        var rng = SystemRandomNumberGenerator()
        let millis = UInt64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        return make(millisecondsSinceEpoch: millis, using: &rng)
    }

    /// Deterministic constructor used by tests to assert ordering and bit layout.
    public static func make(
        millisecondsSinceEpoch millis: UInt64,
        using rng: inout some RandomNumberGenerator
    ) -> UUID {
        var b = [UInt8](repeating: 0, count: 16)
        // 48-bit big-endian timestamp.
        b[0] = UInt8((millis >> 40) & 0xFF)
        b[1] = UInt8((millis >> 32) & 0xFF)
        b[2] = UInt8((millis >> 24) & 0xFF)
        b[3] = UInt8((millis >> 16) & 0xFF)
        b[4] = UInt8((millis >> 8) & 0xFF)
        b[5] = UInt8(millis & 0xFF)
        for i in 6 ..< 16 {
            b[i] = UInt8.random(in: 0 ... 255, using: &rng)
        }
        b[6] = (b[6] & 0x0F) | 0x70 // version 7
        b[8] = (b[8] & 0x3F) | 0x80 // variant 0b10
        return UUID(uuid: (
            b[0],
            b[1],
            b[2],
            b[3],
            b[4],
            b[5],
            b[6],
            b[7],
            b[8],
            b[9],
            b[10],
            b[11],
            b[12],
            b[13],
            b[14],
            b[15]
        ))
    }
}
