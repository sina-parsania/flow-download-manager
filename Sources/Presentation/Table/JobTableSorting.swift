// SPDX-License-Identifier: GPL-3.0-or-later

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
}

/// Pure ordering for `JobRowModel` rows. Numeric columns compare raw values
/// (bytes / seconds / fractions), not formatted strings.
public enum JobTableSorting {
    /// Stable sort: primary column, then name, then id.
    public static func sorted(
        _ rows: [JobRowModel],
        by key: JobTableSortKey,
        ascending: Bool
    ) -> [JobRowModel] {
        rows.sorted { lhs, rhs in
            let primary = compare(lhs, rhs, by: key)
            if primary != .orderedSame {
                return ascending ? primary == .orderedAscending : primary == .orderedDescending
            }
            let byName = lhs.name.localizedStandardCompare(rhs.name)
            if byName != .orderedSame {
                return byName == .orderedAscending
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public static func compare(
        _ lhs: JobRowModel,
        _ rhs: JobRowModel,
        by key: JobTableSortKey
    ) -> ComparisonResult {
        switch key {
        case .status:
            return lhs.state.displayName.localizedStandardCompare(rhs.state.displayName)
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .progress:
            return compareOptionalDouble(lhs.progressFraction, rhs.progressFraction)
        case .speed:
            return compareInt64(lhs.speedBytesPerSecond, rhs.speedBytesPerSecond)
        case .eta:
            return compareOptionalInt(lhs.etaSeconds, rhs.etaSeconds)
        case .size:
            return compareOptionalInt64(lhs.totalBytes, rhs.totalBytes)
        case .category:
            let left = categorySortKey(lhs)
            let right = categorySortKey(rhs)
            return left.localizedStandardCompare(right)
        }
    }

    private static func categorySortKey(_ row: JobRowModel) -> String {
        ([row.categoryKey] + (row.projectName.map { [$0] } ?? []) + row.tagNames)
            .joined(separator: " · ")
    }

    private static func compareInt64(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    /// Missing values sort after known ones when ascending (and before when descending
    /// via the caller flipping the result).
    private static func compareOptionalInt64(_ lhs: Int64?, _ rhs: Int64?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (l?, r?): return compareInt64(l, r)
        }
    }

    private static func compareOptionalInt(_ lhs: Int?, _ rhs: Int?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (l?, r?):
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        }
    }

    private static func compareOptionalDouble(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (l?, r?):
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
            return .orderedSame
        }
    }
}
