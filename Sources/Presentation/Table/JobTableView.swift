// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// AppKit-backed, virtualized download table bridged into SwiftUI
/// (`02-architecture.md` §14, `03-design-system-ui-ux.md` §5).
///
/// Uses a classic `NSTableViewDataSource` (not DiffableDataSource) so column
/// header sorting can reorder rows with a plain `reloadData`. Diffable snapshots
/// on macOS often keep item order stable when only the sequence of existing IDs
/// changes — which made the sort arrows appear while rows stayed put.
@MainActor
public struct JobTableView: NSViewRepresentable {
    public let rows: [JobRowModel]
    @Binding public var selectedID: JobRowModel.ID?

    public init(rows: [JobRowModel], selectedID: Binding<JobRowModel.ID?>) {
        self.rows = rows
        _selectedID = selectedID
    }

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
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.identifier.rawValue,
                ascending: true
            )
            tableView.addTableColumn(column)
        }

        context.coordinator.tableView = tableView
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.replaceRows(rows, reload: true)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.replaceRows(rows, reload: true)
        context.coordinator.syncSelection(selectedID)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        @Binding private var selectedID: JobRowModel.ID?
        private var sourceRows: [JobRowModel] = []
        private var displayedRows: [JobRowModel] = []
        private var sortKey: JobTableSortKey?
        private var sortAscending = true
        private var isApplyingSelection = false

        init(selectedID: Binding<JobRowModel.ID?>) {
            _selectedID = selectedID
        }

        func replaceRows(_ rows: [JobRowModel], reload: Bool) {
            sourceRows = rows
            displayedRows = ordered(rows)
            guard reload, let tableView else { return }
            let previousID = selectedID
            tableView.reloadData()
            syncSelection(previousID)
        }

        private func ordered(_ rows: [JobRowModel]) -> [JobRowModel] {
            guard let sortKey else { return rows }
            return JobTableSorting.sorted(rows, by: sortKey, ascending: sortAscending)
        }

        func syncSelection(_ id: JobRowModel.ID?) {
            guard let tableView else { return }
            isApplyingSelection = true
            defer { isApplyingSelection = false }
            if let id, let row = displayedRows.firstIndex(where: { $0.id == id }) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else if id == nil {
                tableView.deselectAll(nil)
            }
        }

        // MARK: NSTableViewDataSource

        public func numberOfRows(in tableView: NSTableView) -> Int {
            displayedRows.count
        }

        // MARK: NSTableViewDelegate

        public func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row >= 0, row < displayedRows.count,
                  let tableColumn,
                  let spec = JobColumn.all.first(where: { $0.identifier == tableColumn.identifier })
            else { return nil }
            return spec.makeCell(tableView, displayedRows[row])
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let row = tableView.selectedRow
            selectedID = (row >= 0 && row < displayedRows.count) ? displayedRows[row].id : nil
        }

        @objc
        public func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            _ = oldDescriptors
            guard let descriptor = tableView.sortDescriptors.first,
                  let keyRaw = descriptor.key,
                  let key = JobTableSortKey(rawValue: keyRaw)
            else {
                sortKey = nil
                sortAscending = true
                replaceRows(sourceRows, reload: true)
                return
            }
            sortKey = key
            sortAscending = descriptor.ascending
            replaceRows(sourceRows, reload: true)
        }
    }
}
