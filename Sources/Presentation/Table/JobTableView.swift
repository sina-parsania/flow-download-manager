// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Application
import Domain
import SwiftUI
import XPCContracts

/// Selects the right-clicked row when it is not already part of the selection,
/// so the context menu always targets the row under the pointer. Clicks in the
/// empty area below the last row clear the selection.
private final class JobListTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        let row = row(at: local)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if row(at: local) < 0 {
            deselectAll(nil)
        }
        super.mouseDown(with: event)
    }
}

/// AppKit-backed download table with multi-select, column sorting, and a
/// right-click context menu for bulk Pause / Resume / Cancel / Remove.
@MainActor
public struct JobTableView: NSViewRepresentable {
    public let rows: [JobRowModel]
    @Binding public var selectedID: JobRowModel.ID?
    @Binding public var selectedIDs: Set<JobRowModel.ID>
    public var onOpenInspector: ((JobRowModel.ID) -> Void)?
    public var onCommand: ((JobCommandKind) -> Void)?
    public var onRemoveFromList: (() -> Void)?
    public var onRemoveFiles: (() -> Void)?
    public var onRevealInFinder: (() -> Void)?

    public init(
        rows: [JobRowModel],
        selectedID: Binding<JobRowModel.ID?>,
        selectedIDs: Binding<Set<JobRowModel.ID>>,
        onOpenInspector: ((JobRowModel.ID) -> Void)? = nil,
        onCommand: ((JobCommandKind) -> Void)? = nil,
        onRemoveFromList: (() -> Void)? = nil,
        onRemoveFiles: (() -> Void)? = nil,
        onRevealInFinder: (() -> Void)? = nil
    ) {
        self.rows = rows
        _selectedID = selectedID
        _selectedIDs = selectedIDs
        self.onOpenInspector = onOpenInspector
        self.onCommand = onCommand
        self.onRemoveFromList = onRemoveFromList
        self.onRemoveFiles = onRemoveFiles
        self.onRevealInFinder = onRevealInFinder
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedID: $selectedID,
            selectedIDs: $selectedIDs,
            onOpenInspector: onOpenInspector,
            onCommand: onCommand,
            onRemoveFromList: onRemoveFromList,
            onRemoveFiles: onRemoveFiles,
            onRevealInFinder: onRevealInFinder
        )
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let tableView = JobListTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 56
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        // Click-drag across rows extends the selection (with multi-select on).
        tableView.allowsTypeSelect = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.setAccessibilityLabel("Downloads")
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))

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
        tableView.menu = context.coordinator.makeContextMenu()
        context.coordinator.replaceRows(rows, reload: true)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onOpenInspector = onOpenInspector
        context.coordinator.onCommand = onCommand
        context.coordinator.onRemoveFromList = onRemoveFromList
        context.coordinator.onRemoveFiles = onRemoveFiles
        context.coordinator.onRevealInFinder = onRevealInFinder
        context.coordinator.replaceRows(rows, reload: true)
        context.coordinator.syncSelection(selectedIDs, primary: selectedID)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        weak var tableView: NSTableView?
        @Binding private var selectedID: JobRowModel.ID?
        @Binding private var selectedIDs: Set<JobRowModel.ID>
        var onOpenInspector: ((JobRowModel.ID) -> Void)?
        var onCommand: ((JobCommandKind) -> Void)?
        var onRemoveFromList: (() -> Void)?
        var onRemoveFiles: (() -> Void)?
        var onRevealInFinder: (() -> Void)?
        private var sourceRows: [JobRowModel] = []
        private var displayedRows: [JobRowModel] = []
        private var sortKey: JobTableSortKey?
        private var sortAscending = true
        private var isApplyingSelection = false

        init(
            selectedID: Binding<JobRowModel.ID?>,
            selectedIDs: Binding<Set<JobRowModel.ID>>,
            onOpenInspector: ((JobRowModel.ID) -> Void)?,
            onCommand: ((JobCommandKind) -> Void)?,
            onRemoveFromList: (() -> Void)?,
            onRemoveFiles: (() -> Void)?,
            onRevealInFinder: (() -> Void)?
        ) {
            _selectedID = selectedID
            _selectedIDs = selectedIDs
            self.onOpenInspector = onOpenInspector
            self.onCommand = onCommand
            self.onRemoveFromList = onRemoveFromList
            self.onRemoveFiles = onRemoveFiles
            self.onRevealInFinder = onRevealInFinder
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow
            guard row >= 0, row < displayedRows.count else { return }
            onOpenInspector?(displayedRows[row].id)
        }

        func replaceRows(_ rows: [JobRowModel], reload: Bool) {
            sourceRows = rows
            displayedRows = ordered(rows)
            guard reload, let tableView else { return }
            let keep = selectedIDs
            let primary = selectedID
            tableView.reloadData()
            syncSelection(keep, primary: primary)
        }

        private func ordered(_ rows: [JobRowModel]) -> [JobRowModel] {
            guard let sortKey else { return rows }
            return JobTableSorting.sorted(rows, by: sortKey, ascending: sortAscending)
        }

        func syncSelection(_ ids: Set<JobRowModel.ID>, primary: JobRowModel.ID?) {
            guard let tableView else { return }
            isApplyingSelection = true
            defer { isApplyingSelection = false }
            var indexes = IndexSet()
            for (index, row) in displayedRows.enumerated() where ids.contains(row.id) {
                indexes.insert(index)
            }
            if indexes.isEmpty {
                tableView.deselectAll(nil)
            } else {
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
                if let primary,
                   let focus = displayedRows.firstIndex(where: { $0.id == primary }) {
                    tableView.scrollRowToVisible(focus)
                }
            }
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu(title: "Downloads")
            menu.delegate = self
            menu.autoenablesItems = false
            return menu
        }

        public func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let states = selectedDisplayedRows().map(\.state)
            let hasSelection = !states.isEmpty

            func item(_ title: String, action: Selector, enabled: Bool) -> NSMenuItem {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                entry.isEnabled = enabled
                return entry
            }

            menu.addItem(item(
                "Pause",
                action: #selector(contextPause),
                enabled: hasSelection && BulkJobCommandFilter.anyCanPause(states)
            ))
            menu.addItem(item(
                "Resume",
                action: #selector(contextResume),
                enabled: hasSelection && BulkJobCommandFilter.anyCanResume(states)
            ))
            menu.addItem(item(
                "Cancel",
                action: #selector(contextCancel),
                enabled: hasSelection && BulkJobCommandFilter.anyCanCancel(states)
            ))
            menu.addItem(.separator())
            menu.addItem(item(
                "Retry",
                action: #selector(contextRetry),
                enabled: hasSelection && BulkJobCommandFilter.anyCanRetry(states)
            ))
            menu.addItem(item(
                "Restart",
                action: #selector(contextRestart),
                enabled: hasSelection && BulkJobCommandFilter.anyCanRestart(states)
            ))
            menu.addItem(.separator())
            menu.addItem(item(
                "Open in Finder",
                action: #selector(contextReveal),
                enabled: hasSelection && onRevealInFinder != nil
            ))
            menu.addItem(.separator())
            menu.addItem(item(
                "Remove from List",
                action: #selector(contextRemoveList),
                enabled: hasSelection && BulkJobCommandFilter.anyCanRemove(states)
            ))
            let removeFiles = item(
                "Remove Files…",
                action: #selector(contextRemoveFiles),
                enabled: hasSelection && BulkJobCommandFilter.anyCanRemove(states)
            )
            removeFiles.isAlternate = false
            menu.addItem(removeFiles)
        }

        private func selectedDisplayedRows() -> [JobRowModel] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { index in
                guard index >= 0, index < displayedRows.count else { return nil }
                return displayedRows[index]
            }
        }

        @objc private func contextPause() {
            onCommand?(.pause)
        }

        @objc private func contextResume() {
            onCommand?(.resume)
        }

        @objc private func contextCancel() {
            onCommand?(.cancel)
        }

        @objc private func contextRetry() {
            onCommand?(.retry)
        }

        @objc private func contextRestart() {
            onCommand?(.restart)
        }

        @objc private func contextReveal() {
            onRevealInFinder?()
        }

        @objc private func contextRemoveList() {
            onRemoveFromList?()
        }

        @objc private func contextRemoveFiles() {
            onRemoveFiles?()
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

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            _ = row
            return FlowTableRowView()
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let indexes = tableView.selectedRowIndexes
            let ids = Set(indexes.compactMap { index -> JobRowModel.ID? in
                guard index >= 0, index < displayedRows.count else { return nil }
                return displayedRows[index].id
            })
            selectedIDs = ids
            if let row = Optional(tableView.selectedRow),
               row >= 0, row < displayedRows.count {
                selectedID = displayedRows[row].id
            } else {
                selectedID = ids.first
            }
        }

        /// Right-click on an unselected row selects it before the menu opens.
        public func tableView(
            _ tableView: NSTableView,
            didClick tableColumn: NSTableColumn
        ) {
            _ = tableColumn
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
