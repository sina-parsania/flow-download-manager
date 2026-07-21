// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The main library window: sidebar + AppKit-backed table + inspector
/// (`03-design-system-ui-ux.md` §3). The inspector toggles with ⌥⌘I and its state
/// is remembered per window. `Add` opens a Phase 0 informational sheet and never
/// pretends to queue a download (`bootstrap prompt §5`).
public struct RootView: View {
    @ObservedObject private var model: LibraryModel
    @ObservedObject private var launchAgent: LaunchAgentModel

    public init(model: LibraryModel, launchAgent: LaunchAgentModel) {
        self.model = model
        self.launchAgent = launchAgent
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model, launchAgent: launchAgent)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            tableContent
                .navigationTitle("Downloads")
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search downloads")
                .toolbar { toolbarContent }
                .inspector(isPresented: $model.inspectorVisible) {
                    InspectorView(row: model.selectedRow)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                }
        }
        .sheet(isPresented: $model.addSheetPresented) { AddDownloadsSheet() }
    }

    @ViewBuilder
    private var tableContent: some View {
        if let reason = model.emptyReason {
            LibraryEmptyState(reason: reason) { model.addSheetPresented = true }
        } else {
            JobTableView(rows: model.visibleRows, selectedID: $model.selectedID)
                .accessibilityLabel("Download list")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.addSheetPresented = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add downloads")

            Button {
                model.inspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Toggle inspector")
        }
    }
}

/// Empty and no-matches states are distinct (`03-design-system-ui-ux.md` §13).
private struct LibraryEmptyState: View {
    let reason: LibraryModel.EmptyReason
    let onAdd: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: reason == .noDownloads ? "arrow.down.circle" : "magnifyingglass")
        } description: {
            Text(message)
        } actions: {
            if reason == .noDownloads {
                Button("Add Downloads", action: onAdd)
            }
        }
    }

    private var title: String {
        reason == .noDownloads ? "No downloads yet" : "No matches"
    }

    private var message: String {
        reason == .noDownloads
            ? "Use Add to paste or drop links and preview them. Queuing and transfers arrive in a later release."
            : "No downloads match the current filter and search."
    }
}
