// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import XPCContracts

/// The main library window: sidebar + AppKit-backed table + inspector
/// (`03-design-system-ui-ux.md` §3).
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
                    InspectorView(row: model.selectedRow, onCommand: { command in
                        Task { await model.controlSelected(command) }
                    })
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                }
        }
        .sheet(isPresented: $model.addSheetPresented) {
            AddDownloadsSheet()
                .environmentObject(model)
        }
        .task {
            DownloadNotificationCenter.shared.requestAuthorizationIfNeeded()
            model.startPolling()
            await model.refreshFromEngine()
        }
        .onDisappear {
            model.stopPolling()
        }
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
                Task { await model.controlSelected(.pause) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .disabled(!canPause)
            .help("Pause selected download")

            Button {
                Task { await model.controlSelected(.resume) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .disabled(!canResume)
            .help("Resume selected download")

            Button {
                Task { await model.controlSelected(.cancel) }
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .disabled(model.selectedRow == nil)
            .help("Cancel selected download")

            Button {
                Task { await model.controlSelected(.retry) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .disabled(!canRetry)
            .help("Retry selected download")

            Button {
                model.inspectorVisible.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Toggle inspector")
        }
    }

    private var canPause: Bool {
        guard let state = model.selectedRow?.state else { return false }
        return [.queued, .connecting, .downloading, .scheduled].contains(state)
    }

    private var canResume: Bool {
        model.selectedRow?.state == .paused
    }

    private var canRetry: Bool {
        guard let state = model.selectedRow?.state else { return false }
        return state == .failed || state == .cancelled
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
            ? "Use Add to paste links, review them, and queue downloads to the background engine."
            : "No downloads match the current filter and search."
    }
}
