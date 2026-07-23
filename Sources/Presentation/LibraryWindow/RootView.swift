// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import SwiftUI
import UniformTypeIdentifiers
import XPCContracts

/// The main library window: sidebar + AppKit-backed table + inspector
/// (`03-design-system-ui-ux.md` §3).
public struct RootView: View {
    @ObservedObject private var model: LibraryModel
    @ObservedObject private var launchAgent: LaunchAgentModel
    @State private var isDropTargeted = false

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
                    InspectorView(
                        row: model.selectedRow,
                        engineClient: model.engineClient,
                        onCommand: { command in
                            Task { await model.controlSelected(command) }
                        },
                        onPriorityBump: { delta in
                            Task { await model.bumpSelectedPriority(by: delta) }
                        },
                        onOrganizationChanged: {
                            Task { await model.refreshFromEngine() }
                        }
                    )
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                }
        }
        .sheet(isPresented: $model.addSheetPresented) {
            AddDownloadsSheet()
                .environmentObject(model)
        }
        .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
            handleWindowDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
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
            .help("Retry selected download (keep partial)")

            Button {
                Task { await model.controlSelected(.restart) }
            } label: {
                Label("Restart", systemImage: "arrow.counterclockwise")
            }
            .disabled(!canRestart)
            .help("Restart selected download from scratch (wipe partial)")

            Button {
                Task { await model.pauseAll() }
            } label: {
                Label("Pause All", systemImage: "pause.circle")
            }
            .accessibilityLabel("Pause All")
            .help("Pause all active and queued downloads")

            Button {
                Task { await model.resumeAll() }
            } label: {
                Label("Resume All", systemImage: "play.circle")
            }
            .accessibilityLabel("Resume All")
            .help("Resume all paused downloads")

            Button {
                Task { await model.removeSelectedTerminal() }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(!canRemove)
            .accessibilityLabel("Remove selected completed or failed download")
            .help("Remove selected completed, cancelled, or failed download from the library")

            Button {
                Task { await model.clearFailed() }
            } label: {
                Label("Clear Failed", systemImage: "trash.slash")
            }
            .disabled(!hasFailed)
            .accessibilityLabel("Clear Failed")
            .help("Remove all failed downloads from the library")

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

    private var canRestart: Bool {
        guard let state = model.selectedRow?.state else { return false }
        return state == .paused || state == .failed || state == .cancelled
    }

    private var canRemove: Bool {
        guard let state = model.selectedRow?.state else { return false }
        return DeleteJobGuard.allowsDelete(state)
    }

    private var hasFailed: Bool {
        model.rows.contains { DeleteJobGuard.allowsClearFailed($0.state) }
    }

    private func handleWindowDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL? = if let data = item as? Data {
                        URL(dataRepresentation: data, relativeTo: nil)
                    } else if let url = item as? URL {
                        url
                    } else {
                        nil
                    }
                    guard let url, ImportTextIngest.isImportableFile(url) else { return }
                    Task { @MainActor in
                        model.handleDroppedFileURL(url)
                    }
                }
                handled = true
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string, !string.isEmpty else { return }
                    Task { @MainActor in
                        model.handleDroppedText(string)
                    }
                }
                handled = true
            }
        }
        return handled
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
