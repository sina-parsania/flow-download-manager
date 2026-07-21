// SPDX-License-Identifier: GPL-3.0-or-later

import Persistence
import XCTest

/// Constraint enforcement and integrity checks on schema v1
/// (`04-domain-and-data-contracts.md` §7, `08-validation-commands.md` §10).
final class DatabaseIntegrityTests: XCTestCase {
    private func makeDatabase() throws -> (EngineDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-inttest-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("engine.sqlite")
        return try (EngineDatabase(url: url), url)
    }

    func testIntegrityCheckPassesAfterSeed() throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try db.seedFixtureJob()
        XCTAssertTrue(try db.integrityCheck())
        XCTAssertNoThrow(try db.verifyIntegrity())
    }

    func testForeignKeyViolationRejected() throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A job referencing a non-existent resource/category/profile must be rejected.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let job = JobRecord(
            id: "00000000-0000-7000-8000-0000000000ff", batchID: nil,
            resourceID: "missing", state: "queued", priority: 0, queuePosition: 0,
            categoryID: "missing", projectID: nil, destinationProfileID: "missing",
            scheduleID: nil, createdAt: now, updatedAt: now, revision: 1, terminalReason: nil
        )
        XCTAssertThrowsError(try db.insert(job))
    }

    func testTerminalStateRequiresReason() throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Seed the FK-valid graph, then attempt a failed job with no terminal reason.
        let jobID = try db.seedFixtureJob()
        _ = jobID
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let badTerminal = JobRecord(
            id: "00000000-0000-7000-8000-0000000000fe", batchID: nil,
            resourceID: "00000000-0000-7000-8000-0000000000a1", state: "failed",
            priority: 0, queuePosition: 0,
            categoryID: "00000000-0000-7000-8000-0000000000c1", projectID: nil,
            destinationProfileID: "00000000-0000-7000-8000-0000000000d1", scheduleID: nil,
            createdAt: now, updatedAt: now, revision: 1, terminalReason: nil
        )
        XCTAssertThrowsError(try db.insert(badTerminal), "failed state with nil terminalReason must be rejected")
    }

    func testInvalidJobStateRejected() throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try db.seedFixtureJob()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bogusState = JobRecord(
            id: "00000000-0000-7000-8000-0000000000fd", batchID: nil,
            resourceID: "00000000-0000-7000-8000-0000000000a1", state: "not_a_real_state",
            priority: 0, queuePosition: 0,
            categoryID: "00000000-0000-7000-8000-0000000000c1", projectID: nil,
            destinationProfileID: "00000000-0000-7000-8000-0000000000d1", scheduleID: nil,
            createdAt: now, updatedAt: now, revision: 1, terminalReason: nil
        )
        XCTAssertThrowsError(try db.insert(bogusState))
    }

    func testSegmentRangeInvariantEnforced() throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let jobID = try db.seedFixtureJob()

        let attemptID = "00000000-0000-7000-8000-0000000000b1"
        try db.insert(AttemptRecord(
            id: attemptID, jobID: jobID, ordinal: 0, startedAt: nil, endedAt: nil,
            outcome: nil, transferredBytes: 0, retryCount: 0,
            dependencyVersions: nil, sanitizedError: nil
        ))

        // committedExclusive > upperBoundExclusive violates the CHECK.
        let badSegment = SegmentRecord(
            id: "00000000-0000-7000-8000-0000000000e1", attemptID: attemptID,
            lowerBound: 0, upperBoundExclusive: 100, committedExclusive: 200,
            state: "active", retryCount: 0, rollingThroughput: 0
        )
        XCTAssertThrowsError(try db.insert(badSegment))

        // A valid segment is accepted.
        let goodSegment = SegmentRecord(
            id: "00000000-0000-7000-8000-0000000000e2", attemptID: attemptID,
            lowerBound: 0, upperBoundExclusive: 100, committedExclusive: 50,
            state: "active", retryCount: 0, rollingThroughput: 0
        )
        XCTAssertNoThrow(try db.insert(goodSegment))
    }

    func testUniqueCategoryKeyEnforced() throws {
        let (db, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try db.seedFixtureJob() // inserts category stableKey "documents"
        let dup = CategoryRecord(
            id: "00000000-0000-7000-8000-0000000000c2", stableKey: "documents",
            displayNameKey: "category.documents", systemSymbol: "doc", destinationProfileID: nil
        )
        XCTAssertThrowsError(try db.insert(dup))
    }
}
