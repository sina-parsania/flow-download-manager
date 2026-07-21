// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Sidebar filter: independent Library (status) and Category filters
/// (`03-design-system-ui-ux.md` §2). A category never implies a folder.
public enum LibraryFilter: Hashable, Sendable {
    case all
    case active
    case queued
    case paused
    case completed
    case failed
    case category(String)

    public func matches(_ row: JobRowModel) -> Bool {
        switch self {
        case .all: return true
        case .active: return row.statusRole == .active
        case .queued: return row.statusRole == .queued
        case .paused: return row.statusRole == .paused
        case .completed: return row.state == .completed
        case .failed: return row.state == .failed
        case let .category(key): return row.categoryKey == key
        }
    }
}

/// Observable state for the library window. Holds immutable read snapshots plus UI
/// state (selection, search, filter, inspector visibility). Filtering/search are
/// pure and derived; search is debounced at the view.
@MainActor
public final class LibraryModel: ObservableObject {
    @Published public var rows: [JobRowModel]
    @Published public var selectedID: JobRowModel.ID?
    @Published public var searchText: String = ""
    @Published public var filter: LibraryFilter = .all
    @Published public var inspectorVisible: Bool = true
    @Published public var addSheetPresented: Bool = false

    public init(rows: [JobRowModel]) {
        self.rows = rows
    }

    /// Rows after applying the current filter and search. Distinguishes "no
    /// downloads" from "no matches" via ``emptyReason``.
    public var visibleRows: [JobRowModel] {
        let filtered = rows.filter { filter.matches($0) }
        guard !searchText.isEmpty else { return filtered }
        let needle = searchText
        return filtered.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.sourceHost.localizedCaseInsensitiveContains(needle)
        }
    }

    public var selectedRow: JobRowModel? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

    public enum EmptyReason: Sendable { case noDownloads, noMatches }

    public var emptyReason: EmptyReason? {
        guard visibleRows.isEmpty else { return nil }
        return (rows.isEmpty && searchText.isEmpty && filter == .all) ? .noDownloads : .noMatches
    }
}
