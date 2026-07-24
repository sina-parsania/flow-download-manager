// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Persistence
import XCTest

final class HostSettingRepositoryTests: XCTestCase {
    func testNormalizeHostFromURLAndBareName() {
        XCTAssertEqual(
            HostSettingRepository.normalizeHost("https://CDN.Example.TEST/path"),
            "cdn.example.test"
        )
        XCTAssertEqual(HostSettingRepository.normalizeHost("CDN.Example.TEST"), "cdn.example.test")
        XCTAssertNil(HostSettingRepository.normalizeHost(""))
        XCTAssertNil(HostSettingRepository.normalizeHost("not a host"))
    }

    func testUpsertListGetAndDelete() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-hostset-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)

        let stored = try HostSettingRepository.upsert(
            database: database,
            setting: HostSettingRepository.Setting(
                host: "https://CDN.Example.TEST/x",
                maxConnections: 4,
                maxBytesPerSecond: 2_000_000,
                userAgent: "FlowTest/1.0"
            )
        )
        XCTAssertEqual(stored.host, "cdn.example.test")
        XCTAssertEqual(stored.maxConnections, 4)

        let listed = try HostSettingRepository.list(database: database)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].userAgent, "FlowTest/1.0")

        let fetched = try HostSettingRepository.get(database: database, host: "cdn.example.test")
        XCTAssertEqual(fetched?.maxBytesPerSecond, 2_000_000)

        XCTAssertTrue(try HostSettingRepository.delete(database: database, host: "CDN.Example.TEST"))
        XCTAssertTrue(try HostSettingRepository.list(database: database).isEmpty)
    }

    func testRejectsOutOfRangeConnections() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-hostset-bad-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)

        XCTAssertThrowsError(
            try HostSettingRepository.upsert(
                database: database,
                setting: HostSettingRepository.Setting(host: "a.test", maxConnections: 64)
            )
        ) { error in
            XCTAssertEqual(error as? HostSettingRepositoryError, .invalidMaxConnections)
        }
    }
}
