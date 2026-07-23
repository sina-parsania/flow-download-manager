// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Persistence
import XCTest

final class HostObservationRepositoryTests: XCTestCase {
    func testSetGetAndExpiry() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-hostobs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)

        try HostObservationRepository.set(
            database: database,
            host: "cdn.example.test",
            observation: HostObservationRepository.Observation(maxSegments: 4, rangeOK: true),
            expiresAt: Date().addingTimeInterval(3600)
        )
        let live = try HostObservationRepository.get(database: database, host: "cdn.example.test")
        XCTAssertEqual(live?.maxSegments, 4)
        XCTAssertEqual(live?.rangeOK, true)

        try HostObservationRepository.set(
            database: database,
            host: "cdn.example.test",
            observation: HostObservationRepository.Observation(maxSegments: 2, rangeOK: true),
            expiresAt: Date().addingTimeInterval(-1)
        )
        let expired = try HostObservationRepository.get(database: database, host: "cdn.example.test")
        XCTAssertNil(expired)
    }
}
