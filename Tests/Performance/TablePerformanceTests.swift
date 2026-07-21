// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Presentation
import XCTest

/// Performance baselines for the 10,000-row library
/// (`05-quality-testing-release-gates.md` §5). Records CPU/clock via XCTest
/// metrics; the collected result is compared against an approved baseline by
/// `make performance-compare`.
@MainActor
final class TablePerformanceTests: XCTestCase {
    private let rowCount = 10000

    func testBuild10kFixtures() {
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            _ = JobRowFixtures.make(count: rowCount)
        }
    }

    func testFilterAndSearchOver10k() {
        let model = LibraryModel(rows: JobRowFixtures.make(count: rowCount))
        model.filter = .active
        model.searchText = "download-0"
        measure(metrics: [XCTClockMetric()]) {
            _ = model.visibleRows
        }
    }

    /// Applying a 10,000-row identity-stable snapshot to the diffable data source
    /// (the "cold load" the table performs). Only visible cells realize.
    func testDiffableApply10k() {
        let rows = JobRowFixtures.make(count: rowCount)
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("c")))
        let dataSource = NSTableViewDiffableDataSource<Int, UUID>(tableView: table) { _, _, _, _ in
            NSView()
        }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
            snapshot.appendSections([0])
            snapshot.appendItems(rows.map(\.id), toSection: 0)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }
}
