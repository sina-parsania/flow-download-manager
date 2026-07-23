// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Persistence
import SharedSecurity
import XCTest

final class ProfileAndScheduleTests: XCTestCase {
    func testCredentialProfileRoundTripUserpwd() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-cred-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)
        let store = InMemorySecretStore()
        let id = UUID().uuidString.lowercased()
        try ProfileRepository.upsertCredentialProfile(
            database: database,
            id: id,
            metadata: CredentialProfileMetadata(displayName: "Test", username: "alice"),
            passwordUTF8: Data("s3cret".utf8),
            secretStore: store
        )
        let userpwd = try ProfileRepository.loadUserpwd(
            database: database,
            profileID: id,
            secretStore: store
        )
        XCTAssertEqual(userpwd, "alice:s3cret")
    }

    func testProxyProfileURL() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-proxy-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)
        let id = UUID().uuidString.lowercased()
        try ProfileRepository.upsertProxyProfile(
            database: database,
            id: id,
            metadata: ProxyProfileMetadata(
                displayName: "Local",
                kind: "socks5",
                host: "127.0.0.1",
                port: 1080
            )
        )
        let url = try ProfileRepository.loadProxyURL(database: database, profileID: id)
        XCTAssertEqual(url, "socks5://127.0.0.1:1080")
    }

    func testOneShotSchedulePromotion() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-sched-\(UUID().uuidString).sqlite")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-sched-dest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dest)
        }
        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(database: database, defaultDestinationDirectory: dest)
        let scheduleID = UUID().uuidString.lowercased()
        try ProfileRepository.createOneShotSchedule(
            database: database,
            id: scheduleID,
            startAt: Date().addingTimeInterval(-1)
        )
        let inserted = try JobRepository.insertBatch(
            database: database,
            source: "test",
            displayName: nil,
            items: [("http://127.0.0.1/file.bin", "other")]
        )
        let jobID = try XCTUnwrap(inserted.jobIDs.first)
        try database.pool.write { db in
            guard var job = try JobRecord.fetchOne(db, key: jobID) else {
                XCTFail("missing job")
                return
            }
            job.state = "scheduled"
            job.scheduleID = scheduleID
            try job.update(db)
        }
        let promoted = try ProfileRepository.promoteDueScheduledJobs(database: database)
        XCTAssertEqual(promoted, [jobID])
        let rows = try JobRepository.fetchJobRows(database: database)
        XCTAssertEqual(rows.first?.job.state, "queued")
    }
}
