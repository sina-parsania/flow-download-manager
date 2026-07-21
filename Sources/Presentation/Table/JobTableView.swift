// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// AppKit-backed, virtualized download table bridged into SwiftUI
/// (`02-architecture.md` §14, `03-design-system-ui-ux.md` §5). Uses `NSTableView`
/// row/cell reuse and an identity-stable `NSTableViewDiffableDataSource`, so
/// 10,000 rows realize only visible cells. It does NOT render every row as a
/// SwiftUI hierarchy.
@MainActor
public struct JobTableView: NSViewRepresentable {
    public let rows: [JobRowModel]
    @Binding public var selectedID: JobRowModel.ID?

    public init(rows: [JobRowModel], selectedID: Binding<JobRowModel.ID?>) {
        self.rows = rows
        _selectedID = selectedID
    }

    enum Section { case main }

    public func makeCoordinator() -> Coordinator {
        Coordinator(selectedID: $selectedID)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 40
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.setAccessibilityLabel("Downloads")

        for spec in JobColumn.all {
            let column = NSTableColumn(identifier: spec.identifier)
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            tableView.addTableColumn(column)
        }
        tableView.delegate = context.coordinator

        let dataSource = NSTableViewDiffableDataSource<Section, JobRowModel.ID>(tableView: tableView) {
            [coordinator = context.coordinator] tableView, column, _, itemID in
            coordinator.makeCell(tableView: tableView, column: column, itemID: itemID)
        }
        dataSource.defaultRowAnimation = .effectFade
        context.coordinator.dataSource = dataSource
        context.coordinator.tableView = tableView
        context.coordinator.apply(rows: rows, animate: false)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(rows: rows, animate: false)
        context.coordinator.syncSelection(selectedID)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDelegate {
        var dataSource: NSTableViewDiffableDataSource<Section, JobRowModel.ID>?
        weak var tableView: NSTableView?
        @Binding private var selectedID: JobRowModel.ID?
        private var rowByID: [JobRowModel.ID: JobRowModel] = [:]
        private var isApplyingSelection = false

        init(selectedID: Binding<JobRowModel.ID?>) {
            _selectedID = selectedID
        }

        func apply(rows: [JobRowModel], animate: Bool) {
            rowByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var snapshot = NSDiffableDataSourceSnapshot<Section, JobRowModel.ID>()
            snapshot.appendSections([.main])
            snapshot.appendItems(rows.map(\.id), toSection: .main)
            dataSource?.apply(snapshot, animatingDifferences: animate)
        }

        func syncSelection(_ id: JobRowModel.ID?) {
            guard let tableView, let dataSource else { return }
            isApplyingSelection = true
            defer { isApplyingSelection = false }
            if let id, let row = dataSource.row(forItemIdentifier: id), row >= 0 {
                tableView.selectRowIndexes([row], byExtendingSelection: false)
            } else if id == nil {
                tableView.deselectAll(nil)
            }
        }

        func makeCell(tableView: NSTableView, column: NSTableColumn, itemID: JobRowModel.ID) -> NSView {
            guard let model = rowByID[itemID],
                  let spec = JobColumn.all.first(where: { $0.identifier == column.identifier })
            else { return NSView() }
            return spec.makeCell(tableView, model)
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView, let dataSource else { return }
            let row = tableView.selectedRow
            selectedID = row >= 0 ? dataSource.itemIdentifier(forRow: row) : nil
        }
    }
}
