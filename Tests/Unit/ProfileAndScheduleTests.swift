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

    func testCookieProfileJarPathUnderApplicationSupport() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-cookie-\(UUID().uuidString).sqlite")
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-cookie-support-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: support)
        }
        let database = try EngineDatabase(url: dbURL)
        let id = UUID().uuidString.lowercased()
        try ProfileRepository.upsertCookieProfile(
            database: database,
            id: id,
            displayName: "Session"
        )
        let path = try ProfileRepository.cookieJarPath(
            database: database,
            profileID: id,
            applicationSupportRoot: support
        )
        XCTAssertTrue(path.hasSuffix("cookies/\(id).jar"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data())
    }

    func testListCredentialAndProxyProfiles() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-listprof-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)
        let store = InMemorySecretStore()
        let credID = UUID().uuidString.lowercased()
        let proxyID = UUID().uuidString.lowercased()
        try ProfileRepository.upsertCredentialProfile(
            database: database,
            id: credID,
            metadata: CredentialProfileMetadata(displayName: "A", username: "u"),
            passwordUTF8: Data("p".utf8),
            secretStore: store
        )
        try ProfileRepository.upsertProxyProfile(
            database: database,
            id: proxyID,
            metadata: ProxyProfileMetadata(
                displayName: "P", kind: "http", host: "127.0.0.1", port: 8080
            )
        )
        let credentials = try ProfileRepository.listCredentialProfiles(database: database)
        let proxies = try ProfileRepository.listProxyProfiles(database: database)
        XCTAssertEqual(credentials.map(\.id), [credID])
        XCTAssertEqual(proxies.map(\.id), [proxyID])
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

    func testGlobalBandwidthPolicyRoundTrip() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-bw-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let database = try EngineDatabase(url: dbURL)
        XCTAssertNil(try ProfileRepository.fetchGlobalBandwidthPolicy(database: database))
        try ProfileRepository.upsertBandwidthPolicy(
            database: database,
            id: ProfileRepository.globalBandwidthPolicyID,
            name: "Global",
            windowsJSON: #"[{"weekday":null,"startMinute":0,"endMinute":480}]"#,
            maxBytesPerSecond: 50000
        )
        let loaded = try XCTUnwrap(ProfileRepository.fetchGlobalBandwidthPolicy(database: database))
        XCTAssertEqual(loaded.maxBytesPerSecond, 50000)
        XCTAssertTrue(loaded.windowsJSON.contains("480"))
    }
}
