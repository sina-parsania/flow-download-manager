// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import XCTest
import XPCContracts
@testable import Presentation

@MainActor
final class JobChangeMergerTests: XCTestCase {
    func testAppliesUpsertsAndRemovals() {
        let keep = row(id: UUID(), name: "keep", state: .queued)
        let removeID = UUID()
        let remove = row(id: removeID, name: "remove", state: .failed)
        let addID = UUID()
        let batch = JobChangeBatch(
            requestID: UUID().uuidString,
            sequence: 2,
            sinceSequence: 1,
            upserts: [
                snapshot(id: addID, name: "added", state: "downloading"),
                snapshot(id: keep.id, name: "keep-updated", state: "paused")
            ],
            removedJobIDs: [removeID.uuidString],
            hasGap: false
        )
        let outcome = JobChangeMerger.apply(current: [keep, remove], batch: batch) { snap in
            guard let id = UUID(uuidString: snap.id),
                  let state = JobState(rawValue: snap.state)
            else { return nil }
            return row(id: id, name: snap.name, state: state)
        }
        XCTAssertFalse(outcome.needsFullRefresh)
        XCTAssertEqual(outcome.rows.map(\.name), ["keep-updated", "added"])
    }

    func testGapRequestsFullRefresh() {
        let batch = JobChangeBatch(
            requestID: UUID().uuidString,
            sequence: 9,
            sinceSequence: 1,
            upserts: [],
            removedJobIDs: [],
            hasGap: true
        )
        let outcome = JobChangeMerger.apply(current: [], batch: batch) { _ in nil }
        XCTAssertTrue(outcome.needsFullRefresh)
    }

    private func row(id: UUID, name: String, state: JobState) -> JobRowModel {
        JobRowModel(
            id: id,
            name: name,
            sourceHost: "example.test",
            state: state,
            progressFraction: nil,
            bytesTransferred: 0,
            totalBytes: nil,
            speedBytesPerSecond: 0,
            etaSeconds: nil,
            categoryKey: "other",
            projectName: nil,
            tagNames: []
        )
    }

    private func snapshot(id: UUID, name: String, state: String) -> JobSnapshot {
        JobSnapshot(
            id: id.uuidString.lowercased(),
            name: name,
            sourceHost: "example.test",
            sourceURL: "https://example.test/\(name)",
            state: state,
            progressFraction: nil,
            bytesTransferred: 0,
            totalBytes: nil,
            speedBytesPerSecond: 0,
            categoryKey: "other"
        )
    }
}
