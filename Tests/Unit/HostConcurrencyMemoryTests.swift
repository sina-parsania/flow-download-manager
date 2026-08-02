// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Persistence
import XCTest

/// Remembering where the ramp settled turns a 30-40 s climb into a one-off cost
/// per host instead of a cost paid again on every episode in a queue.
///
/// The value is a **starting point**, never a cap — that distinction is what makes
/// it safe to keep per host with no size band, unlike `maxSegments`.
final class HostConcurrencyMemoryTests: XCTestCase {
    private func database() throws -> EngineDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-hostmem-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try EngineDatabase(url: url)
    }

    func testSettledConnectionsRoundTrip() throws {
        let db = try database()
        try HostObservationRepository.set(
            database: db,
            host: "cdn.example",
            observation: .init(maxSegments: nil, rangeOK: true, settledConnections: 20),
            expiresAt: Date().addingTimeInterval(3600)
        )

        let stored = try HostObservationRepository.get(database: db, host: "cdn.example")
        XCTAssertEqual(stored?.settledConnections, 20)
        XCTAssertEqual(stored?.rangeOK, true)
        XCTAssertNil(stored?.maxSegments, "the hard cap must stay unset")
    }

    /// Observations written before this field existed must still decode — an
    /// engine that fails to read its own older rows would silently lose every
    /// host's `rangeOK` too.
    func testObservationWithoutTheFieldStillDecodes() throws {
        let db = try database()
        try HostObservationRepository.set(
            database: db,
            host: "old.example",
            observation: .init(maxSegments: nil, rangeOK: true),
            expiresAt: Date().addingTimeInterval(3600)
        )

        let stored = try HostObservationRepository.get(database: db, host: "old.example")
        XCTAssertEqual(stored?.rangeOK, true)
        XCTAssertNil(stored?.settledConnections, "absent means 'nothing learned', not zero")
    }

    /// Expiry still governs: a stale number must not steer a download for ever.
    func testExpiredMemoryIsNotReturned() throws {
        let db = try database()
        try HostObservationRepository.set(
            database: db,
            host: "stale.example",
            observation: .init(maxSegments: nil, rangeOK: true, settledConnections: 24),
            expiresAt: Date().addingTimeInterval(-1)
        )

        XCTAssertNil(try HostObservationRepository.get(database: db, host: "stale.example"))
    }
}
