// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import EngineAgent
import Foundation
import Persistence
import SharedSecurity
import TestFaultService
import XCTest

/// Restart-from-scratch: wipe partial + clear identity, then complete a full download.
final class RestartFromScratchIntegrationTests: XCTestCase {
    func testStartPauseRestartWipesPartialAndCompletesFullFile() async throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-restart-\(UUID().uuidString)", isDirectory: true)
        let dbURL = root.appendingPathComponent("engine.sqlite")
        let dest = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try EngineDatabase(url: dbURL)
        try JobRepository.ensureProductionSeed(database: database, defaultDestinationDirectory: dest)

        let url = "http://127.0.0.1:\(port)/fixtures/ok"
        let inserted = try JobRepository.insertBatch(
            database: database,
            source: "test",
            displayName: nil,
            items: [(url: url, categoryStableKey: "other")]
        )
        let jobID = try XCTUnwrap(inserted.jobIDs.first)

        let orchestrator = TransferOrchestrator(
            database: database,
            secretStore: InMemorySecretStore()
        )
        await orchestrator.start()
        defer {
            let orch = orchestrator
            Task { await orch.stop() }
        }

        // Start → pause (or fall back if the tiny fixture finishes first).
        var state = try await waitForStates(
            database: database,
            timeout: 10,
            matching: ["downloading", "connecting", "paused", "completed", "failed"]
        )
        if state == "downloading" || state == "connecting" {
            await orchestrator.requestPause(jobID: jobID)
            state = try await waitForStates(
                database: database,
                timeout: 10,
                matching: ["paused", "completed", "failed"]
            )
        }

        if state == "completed" {
            // Fixture finished before pause; re-seed a paused job with a corrupt partial.
            try FileManager.default.removeItem(at: dest)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            _ = try JobRepository.updateJobState(
                database: database,
                id: jobID,
                state: "paused",
                terminalReason: nil,
                expectedRevision: nil
            )
            state = "paused"
        }
        XCTAssertTrue(
            state == "paused" || state == "failed" || state == "cancelled",
            "expected paused/failed/cancelled before restart, got \(state)"
        )

        let partial = dest.appendingPathComponent("ok.partial")
        let corrupt = Data(repeating: 0xAB, count: 512)
        try corrupt.write(to: partial)
        try JobRepository.updateResourceIdentity(
            database: database,
            jobID: jobID,
            finalURL: nil,
            expectedSize: Int64(corrupt.count),
            etag: "\"stale\"",
            mime: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        // Restart-from-scratch (mirrors EngineService.controlJob(.restart)).
        try? FileManager.default.removeItem(at: partial)
        try JobRepository.clearResourceIdentitySize(database: database, jobID: jobID)
        await orchestrator.clearProgress(jobID: jobID)
        await orchestrator.clearControl(jobID: jobID)
        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: "queued",
            terminalReason: nil,
            expectedRevision: nil
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))

        let terminal = try await waitForStates(
            database: database,
            timeout: 15,
            matching: ["completed", "failed", "cancelled"]
        )
        await orchestrator.stop()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(terminal, "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))

        let files = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        let finals = files.filter { !$0.lastPathComponent.hasSuffix(".partial") }
        let promoted = try XCTUnwrap(finals.first)
        XCTAssertEqual(try Data(contentsOf: promoted), FaultHTTPServer.fixtureBody)

        let size = try await database.pool.read { db -> Int64? in
            guard let job = try JobRecord.fetchOne(db, key: jobID),
                  let resource = try ResourceRecord.fetchOne(db, key: job.resourceID)
            else { return nil }
            return resource.expectedSize
        }
        XCTAssertEqual(size, Int64(FaultHTTPServer.fixtureBody.count))
    }

    private func waitForStates(
        database: EngineDatabase,
        timeout: TimeInterval,
        matching: Set<String>
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var state = "queued"
        while Date() < deadline {
            let rows = try JobRepository.fetchJobRows(database: database)
            if let row = rows.first {
                state = row.job.state
                if matching.contains(state) {
                    return state
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return state
    }
}
