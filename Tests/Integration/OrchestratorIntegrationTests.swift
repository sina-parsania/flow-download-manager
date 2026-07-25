// SPDX-License-Identifier: GPL-3.0-or-later

import EngineAgent
import Foundation
import Persistence
import SharedSecurity
import TestFaultService
import XCTest

final class OrchestratorIntegrationTests: XCTestCase {
    func testQueuedJobDownloadsFromFaultServer() async throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-orch-\(UUID().uuidString).sqlite")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-orch-dest-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dest)
        }

        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(database: database, defaultDestinationDirectory: dest)
        let url = "http://127.0.0.1:\(port)/fixtures/ok"
        let inserted = try JobRepository.insertBatch(
            database: database,
            source: "test",
            displayName: nil,
            items: [(url: url, categoryStableKey: "other")]
        )
        XCTAssertEqual(inserted.jobIDs.count, 1)

        let orchestrator = TransferOrchestrator(
            database: database,
            secretStore: InMemorySecretStore()
        )
        await orchestrator.start()
        defer {
            let orch = orchestrator
            Task { await orch.stop() }
        }

        let deadline = Date().addingTimeInterval(15)
        var state = "queued"
        var terminal: String?
        while Date() < deadline {
            let rows = try JobRepository.fetchJobRows(database: database)
            guard let row = rows.first else {
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            state = row.job.state
            terminal = row.job.terminalReason
            if state == "completed" || state == "failed" || state == "cancelled" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await orchestrator.stop()
        // Allow the pump task to exit before unlinking the database file.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state, "completed", "job ended in \(state) reason=\(terminal ?? "nil")")
        guard state == "completed" else { return }

        let files = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        let finals = files.filter { !$0.lastPathComponent.hasSuffix(".partial") }
        let promoted = try XCTUnwrap(finals.first, "expected a promoted file in \(dest.path)")
        let data = try Data(contentsOf: promoted)
        XCTAssertEqual(data, FaultHTTPServer.fixtureBody)
    }

    /// Production orchestrator must not Range-probe fragile credential jobs.
    func testOrchestratorSkipsRangeProbeForCookieJob() async throws {
        try await assertOrchestratorSkipsRangeProbeOnOneShot(
            cookieProfileID: nil,
            customHeadersJSON: #"[{"name":"Cookie","value":"session=test"}]"#
        )
    }

    func testOrchestratorSkipsRangeProbeForAuthorizationJob() async throws {
        try await assertOrchestratorSkipsRangeProbeOnOneShot(
            cookieProfileID: nil,
            customHeadersJSON: #"[{"name":"Authorization","value":"Bearer test-token"}]"#
        )
    }

    func testOrchestratorSkipsRangeProbeForCookieJarJob() async throws {
        let cookieID = UUID().uuidString.lowercased()
        try await assertOrchestratorSkipsRangeProbeOnOneShot(
            cookieProfileID: cookieID,
            customHeadersJSON: nil,
            prepareDatabase: { database, support in
                try ProfileRepository.upsertCookieProfile(
                    database: database,
                    id: cookieID,
                    displayName: "Session"
                )
                _ = try ProfileRepository.cookieJarPath(
                    database: database,
                    profileID: cookieID,
                    applicationSupportRoot: support
                )
            }
        )
    }

    private func assertOrchestratorSkipsRangeProbeOnOneShot(
        cookieProfileID: String?,
        customHeadersJSON: String?,
        prepareDatabase: ((EngineDatabase, URL) throws -> Void)? = nil
    ) async throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-orch-probe-\(UUID().uuidString).sqlite")
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-orch-probe-dest-\(UUID().uuidString)", isDirectory: true)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-orch-probe-support-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.removeItem(at: support)
        }

        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(database: database, defaultDestinationDirectory: dest)
        try prepareDatabase?(database, support)

        let url = "http://127.0.0.1:\(port)/fixtures/once"
        let inserted = try JobRepository.insertBatch(
            database: database,
            source: "test",
            displayName: nil,
            items: [(url: url, categoryStableKey: "other")],
            cookieProfileID: cookieProfileID,
            customHeadersJSON: customHeadersJSON
        )
        XCTAssertEqual(inserted.jobIDs.count, 1)

        let orchestrator = TransferOrchestrator(
            database: database,
            secretStore: InMemorySecretStore(),
            applicationSupportRoot: support
        )
        await orchestrator.start()
        defer {
            let orch = orchestrator
            Task { await orch.stop() }
        }

        let deadline = Date().addingTimeInterval(15)
        var state = "queued"
        while Date() < deadline {
            let rows = try JobRepository.fetchJobRows(database: database)
            guard let row = rows.first else {
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            state = row.job.state
            if state == "completed" || state == "failed" || state == "cancelled" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await orchestrator.stop()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state, "completed")
        XCTAssertEqual(server.rangedRequestCount(), 0)
        let onceRequests = server.logs().filter { $0.contains("/fixtures/once") }
        XCTAssertEqual(onceRequests.count, 1)

        let files = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        let finals = files.filter { !$0.lastPathComponent.hasSuffix(".partial") }
        let promoted = try XCTUnwrap(finals.first)
        XCTAssertEqual(try Data(contentsOf: promoted), FaultHTTPServer.fixtureBody)
    }
}
