// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import XCTest
@testable import Presentation

final class JobTableSortingTests: XCTestCase {
    func testSortsBySizeUsingRawBytes() {
        let small = row(name: "a", total: 100, speed: 0, fraction: 0.2, eta: 50)
        let large = row(name: "b", total: 9000, speed: 0, fraction: 0.9, eta: 10)
        let unknown = row(name: "c", total: nil, speed: 0, fraction: nil, eta: nil)

        let ascending = JobTableSorting.sorted([large, unknown, small], by: .size, ascending: true)
        XCTAssertEqual(ascending.map(\.name), ["a", "b", "c"])

        // Unknown size stays last when flipped — blanks never float to the top.
        let descending = JobTableSorting.sorted([small, unknown, large], by: .size, ascending: false)
        XCTAssertEqual(descending.map(\.name), ["b", "a", "c"])
    }

    func testRowsShowingDashSortLastInBothDirections() {
        // Speed 0 and ETA 0 render "—", so they are blank even though non-nil.
        let idle = row(name: "idle", total: 1, speed: 0, fraction: 0.5, eta: 0)
        let slow = row(name: "slow", total: 1, speed: 10, fraction: 0.5, eta: 90)
        let fast = row(name: "fast", total: 1, speed: 200, fraction: 0.5, eta: 5)

        for key in [JobTableSortKey.speed, .eta] {
            for ascending in [true, false] {
                let names = JobTableSorting.sorted([idle, slow, fast], by: key, ascending: ascending).map(\.name)
                XCTAssertEqual(names.last, "idle", "\(key) ascending=\(ascending)")
            }
        }
        XCTAssertEqual(
            JobTableSorting.sorted([idle, slow, fast], by: .eta, ascending: true).map(\.name),
            ["fast", "slow", "idle"]
        )
    }

    func testTiesBreakByNameAToZRegardlessOfDirection() {
        let b = row(name: "b", total: 5, speed: 0, fraction: nil, eta: nil)
        let a = row(name: "a", total: 5, speed: 0, fraction: nil, eta: nil)
        XCTAssertEqual(JobTableSorting.sorted([b, a], by: .size, ascending: false).map(\.name), ["a", "b"])
        XCTAssertEqual(JobTableSorting.sorted([b, a], by: .size, ascending: true).map(\.name), ["a", "b"])
    }

    func testFirstClickDirectionMatchesFinder() {
        for key in [JobTableSortKey.size, .speed, .progress, .started, .finished] {
            XCTAssertFalse(key.defaultAscending, "\(key) should open largest/newest first")
        }
        for key in [JobTableSortKey.name, .status, .eta, .category, .location] {
            XCTAssertTrue(key.defaultAscending, "\(key) should open A→Z / soonest first")
        }
    }

    func testSortsBySpeedAndProgress() {
        let slow = row(name: "slow", total: 100, speed: 10, fraction: 0.1, eta: 90)
        let fast = row(name: "fast", total: 100, speed: 200, fraction: 0.8, eta: 5)

        XCTAssertEqual(
            JobTableSorting.sorted([slow, fast], by: .speed, ascending: false).map(\.name),
            ["fast", "slow"]
        )
        XCTAssertEqual(
            JobTableSorting.sorted([slow, fast], by: .progress, ascending: true).map(\.name),
            ["slow", "fast"]
        )
    }

    func testSortsByStatusInLifecycleOrder() {
        let paused = row(name: "p", state: .paused, total: 1, speed: 0, fraction: 0.5, eta: nil)
        let done = row(name: "d", state: .completed, total: 1, speed: 0, fraction: 1, eta: nil)
        let active = row(name: "a", state: .downloading, total: 1, speed: 5, fraction: 0.1, eta: 9)
        let failed = row(name: "f", state: .failed, total: 1, speed: 0, fraction: 0.2, eta: nil)
        let ordered = JobTableSorting.sorted([done, failed, paused, active], by: .status, ascending: true)
        // Lifecycle order, not alphabetical ("Completed" would otherwise lead).
        XCTAssertEqual(ordered.map(\.state), [.downloading, .paused, .failed, .completed])
    }

    func testSortsByStartedAndFinishedDates() {
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = Date(timeIntervalSince1970: 1_700_010_000)
        let a = row(name: "a", total: 1, speed: 0, fraction: 1, eta: nil, started: early, finished: late)
        let b = row(name: "b", total: 1, speed: 0, fraction: 1, eta: nil, started: late, finished: early)
        let missing = row(name: "c", total: 1, speed: 0, fraction: 0, eta: nil)

        XCTAssertEqual(
            JobTableSorting.sorted([b, missing, a], by: .started, ascending: true).map(\.name),
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            JobTableSorting.sorted([a, missing, b], by: .finished, ascending: true).map(\.name),
            ["b", "a", "c"]
        )
    }

    func testSortsByLocation() {
        let home = row(
            name: "home", total: 1, speed: 0, fraction: 1, eta: nil,
            location: "/Users/a/Downloads"
        )
        let other = row(
            name: "other", total: 1, speed: 0, fraction: 1, eta: nil,
            location: "/Volumes/T7/Media"
        )
        XCTAssertEqual(
            JobTableSorting.sorted([other, home], by: .location, ascending: true).map(\.name),
            ["home", "other"]
        )
    }

    private func row(
        name: String,
        state: JobState = .downloading,
        total: Int64?,
        speed: Int64,
        fraction: Double?,
        eta: Int?,
        started: Date? = nil,
        finished: Date? = nil,
        location: String? = nil
    ) -> JobRowModel {
        JobRowModel(
            id: UUID(),
            name: name,
            sourceHost: "example.test",
            state: state,
            progressFraction: fraction,
            bytesTransferred: Int64((fraction ?? 0) * Double(total ?? 0)),
            totalBytes: total,
            speedBytesPerSecond: speed,
            etaSeconds: eta,
            categoryKey: "videos",
            projectName: nil,
            tagNames: [],
            startedAt: started,
            completedAt: finished,
            destinationDirectoryPath: location
        )
    }
}
