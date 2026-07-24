// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import SwiftUI
import XPCContracts

/// Compact equal-height download rows (one per line). Dense table remains available.
public struct DownloadBoardView: View {
    public let rows: [JobRowModel]
    @Binding public var selectedID: JobRowModel.ID?
    @Binding public var selectedIDs: Set<JobRowModel.ID>
    public var onCommand: ((JobRowModel.ID, JobCommandKind) -> Void)?
    public var onRevealInFinder: ((JobRowModel.ID) -> Void)?
    public var onRemoveFromLibrary: ((JobRowModel.ID) -> Void)?
    public var onDeleteFromDisk: ((JobRowModel.ID) -> Void)?

    public init(
        rows: [JobRowModel],
        selectedID: Binding<JobRowModel.ID?>,
        selectedIDs: Binding<Set<JobRowModel.ID>> = .constant([]),
        onCommand: ((JobRowModel.ID, JobCommandKind) -> Void)? = nil,
        onRevealInFinder: ((JobRowModel.ID) -> Void)? = nil,
        onRemoveFromLibrary: ((JobRowModel.ID) -> Void)? = nil,
        onDeleteFromDisk: ((JobRowModel.ID) -> Void)? = nil
    ) {
        self.rows = rows
        _selectedID = selectedID
        _selectedIDs = selectedIDs
        self.onCommand = onCommand
        self.onRevealInFinder = onRevealInFinder
        self.onRemoveFromLibrary = onRemoveFromLibrary
        self.onDeleteFromDisk = onDeleteFromDisk
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    DownloadPinCard(
                        row: row,
                        isSelected: selectedIDs.contains(row.id) || selectedID == row.id,
                        onSelect: {
                            selectedID = row.id
                            selectedIDs = [row.id]
                        },
                        onCommand: { command in onCommand?(row.id, command) },
                        onRevealInFinder: { onRevealInFinder?(row.id) },
                        onRemoveFromLibrary: { onRemoveFromLibrary?(row.id) },
                        onDeleteFromDisk: { onDeleteFromDisk?(row.id) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 40)
        }
        .accessibilityLabel("Download board")
    }
}

/// Board vs dense list — board is the primary visual experience.
public enum LibraryLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case board
    case list

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .board: return "Board"
        case .list: return "List"
        }
    }

    public var symbol: String {
        switch self {
        case .board: return "rectangle.3.group"
        case .list: return "list.bullet.rectangle"
        }
    }
}
