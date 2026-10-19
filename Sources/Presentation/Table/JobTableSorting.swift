// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Column sort keys for the download list table. Keys match `NSTableColumn`
/// identifiers so header clicks map 1:1 onto comparators.
public enum JobTableSortKey: String, Sendable, CaseIterable {
    case status
    case name
    case progress
    case speed
    case eta
    case size
    case category
    case started
    case finished
    case location

    /// Direction of the first header click, matching Finder: text and ETA
    /// start A→Z / soonest-first; sizes, rates, progress and dates start
    /// biggest / newest-first.
    public var defaultAscending: Bool {
        switch self {
        case .status, .name, .eta, .category, .location: true
        case .progress, .speed, .size, .started, .finished: false
        }
    }
}

/// Pure ordering for `JobRowModel` rows. Numeric columns compare raw values
/// (bytes / seconds / fractions), not formatted strings.
public enum JobTableSorting {
    /// Stable sort: primary column, then name A→Z, then id. Rows whose cell
    /// shows "—" for the column sort last in **both** directions, as in Finder,
    /// so flipping a column never floods the top of the list with blanks.
    public static func sorted(
        _ rows: [JobRowModel],
        by key: JobTableSortKey,
        ascending: Bool
    ) -> [JobRowModel] {
        rows.sorted { lhs, rhs in
            let lhsBlank = isBlank(lhs, for: key)
            let rhsBlank = isBlank(rhs, for: key)
            if lhsBlank != rhsBlank { return rhsBlank }
            if !lhsBlank {
                let primary = compare(lhs, rhs, by: key)
                if primary != .orderedSame {
                    return ascending == (primary == .orderedAscending)
                }
            }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame {
                return byName == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// True when the column renders "—" (or nothing) for this row. Kept in step
    /// with `JobRowFormatting`: speed and ETA show "—" at zero, not only at nil.
    static func isBlank(_ row: JobRowModel, for key: JobTableSortKey) -> Bool {
        switch key {
        case .status, .name, .category: false
        case .progress: row.progressFraction == nil
        case .speed: row.speedBytesPerSecond <= 0
        case .eta: (row.etaSeconds ?? 0) <= 0
        case .size: row.totalBytes == nil
        case .started: row.startedAt == nil
        case .finished: row.completedAt == nil
        case .location: (row.destinationDirectoryPath ?? "").isEmpty
        }
    }

    /// Compares two non-blank rows on `key`.
    static func compare(
        _ lhs: JobRowModel,
        _ rhs: JobRowModel,
        by key: JobTableSortKey
    ) -> ComparisonResult {
        switch key {
        case .status:
            order(statusRank(lhs.state), statusRank(rhs.state))
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .progress:
            order(lhs.progressFraction ?? 0, rhs.progressFraction ?? 0)
        case .speed:
            order(lhs.speedBytesPerSecond, rhs.speedBytesPerSecond)
        case .eta:
            order(lhs.etaSeconds ?? 0, rhs.etaSeconds ?? 0)
        case .size:
            order(lhs.totalBytes ?? 0, rhs.totalBytes ?? 0)
        case .category:
            categorySortKey(lhs).localizedStandardCompare(categorySortKey(rhs))
        case .started:
            order(lhs.startedAt ?? .distantPast, rhs.startedAt ?? .distantPast)
        case .finished:
            order(lhs.completedAt ?? .distantPast, rhs.completedAt ?? .distantPast)
        case .location:
            (lhs.destinationDirectoryPath ?? "").localizedStandardCompare(rhs.destinationDirectoryPath ?? "")
        }
    }

    /// Lifecycle order, not alphabetical: what is moving now, then what is about
    /// to move, then what needs a hand, then what is finished.
    static func statusRank(_ state: JobState) -> Int {
        switch state {
        case .downloading: 0
        case .connecting: 1
        case .verifying, .merging, .postProcessing: 2
        case .retryWaiting: 3
        case .awaitingUserSelection: 4
        case .created, .inspecting: 5
        case .ready, .queued, .scheduled: 6
        case .paused: 7
        case .failed: 8
        case .cancelled: 9
        case .completed: 10
        }
    }

    private static func categorySortKey(_ row: JobRowModel) -> String {
        ([row.categoryKey] + (row.projectName.map { [$0] } ?? []) + row.tagNames)
            .joined(separator: " · ")
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
