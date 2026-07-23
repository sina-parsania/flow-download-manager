// SPDX-License-Identifier: GPL-3.0-or-later

import EngineAgent
import Foundation
import Persistence
import SharedSecurity
import TestFaultService
import XCTest

/// Recovery matrix: interrupted downloading + retryable failed → complete via FaultHTTPServer.
final class RecoveryMatrixIntegrationTests: XCTestCase {
    func testDownloadingPartialRequeueThenResumeCompletes() async throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-recovery-matrix-\(UUID().uuidString)", isDirectory: true)
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

        let partial = dest.appendingPathComponent("ok.partial")
        let firstHalf = FaultHTTPServer.fixtureBody.prefix(2048)
        try Data(firstHalf).write(to: partial)

        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: "downloading",
            terminalReason: nil,
            expectedRevision: nil
        )

        let requeued = try JobRepository.requeueInterruptedTransfers(database: database)
        XCTAssertEqual(requeued, [jobID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        let orchestrator = TransferOrchestrator(
            database: database,
            secretStore: InMemorySecretStore()
        )
        await orchestrator.start()
        defer {
            let orch = orchestrator
            Task { await orch.stop() }
        }

        let state = try await waitForTerminal(database: database, timeout: 15)
        await orchestrator.stop()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state, "completed")
        let files = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        let finals = files.filter { !$0.lastPathComponent.hasSuffix(".partial") }
        let promoted = try XCTUnwrap(finals.first)
        let data = try Data(contentsOf: promoted)
        XCTAssertEqual(data, FaultHTTPServer.fixtureBody)
    }

    func testFailedRetryableRetryCommandCompletes() async throws {
        let server = FaultHTTPServer()
        let port = try server.start()
        defer { server.stop() }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-recovery-retry-\(UUID().uuidString)", isDirectory: true)
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

        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: "failed",
            terminalReason: "networkUnavailable",
            expectedRevision: nil
        )

        // Simulate controlJob(.retry): clear terminal reason and requeue.
        _ = try JobRepository.updateJobState(
            database: database,
            id: jobID,
            state: "queued",
            terminalReason: nil,
            expectedRevision: nil
        )

        let orchestrator = TransferOrchestrator(
            database: database,
            secretStore: InMemorySecretStore()
        )
        await orchestrator.start()
        defer {
            let orch = orchestrator
            Task { await orch.stop() }
        }

        let state = try await waitForTerminal(database: database, timeout: 15)
        await orchestrator.stop()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state, "completed")
        let files = try FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        let finals = files.filter { !$0.lastPathComponent.hasSuffix(".partial") }
        let promoted = try XCTUnwrap(finals.first)
        XCTAssertEqual(try Data(contentsOf: promoted), FaultHTTPServer.fixtureBody)
    }

    private func waitForTerminal(database: EngineDatabase, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var state = "queued"
        while Date() < deadline {
            let rows = try JobRepository.fetchJobRows(database: database)
            guard let row = rows.first else {
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            state = row.job.state
            if state == "completed" || state == "failed" || state == "cancelled" {
                return state
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return state
    }
}
