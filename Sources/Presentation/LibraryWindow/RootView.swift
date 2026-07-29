// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import SwiftUI
import UniformTypeIdentifiers
import XPCContracts

/// Main library window: editorial sidebar + board/list. Job details open as a
/// modal on double-click — never as a selection-driven sidebar.
public struct RootView: View {
    @ObservedObject private var model: LibraryModel
    @ObservedObject private var launchAgent: LaunchAgentModel
    @State private var isDropTargeted = false
    @State private var pendingDiskDeleteIDs: Set<JobRowModel.ID> = []
    @State private var isClearFailedPresented = false
    @Environment(\.flowPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: LibraryModel, launchAgent: LaunchAgentModel) {
        self.model = model
        self.launchAgent = launchAgent
    }

    private var detailSheetPresented: Binding<Bool> {
        Binding(
            get: { model.inspectedID != nil },
            set: { if !$0 { model.closeInspector() } }
        )
    }

    public var body: some View {
        ZStack {
            FlowAtmosphere()
            NavigationSplitView {
                SidebarView(model: model, launchAgent: launchAgent)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                librarySurface
                    .navigationTitle("")
                    .toolbarBackground(.hidden, for: .windowToolbar)
                    .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search the board")
                    .toolbar { toolbarContent }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .sheet(isPresented: $model.addSheetPresented) {
            AddDownloadsSheet()
                .environmentObject(model)
                .environmentObject(launchAgent)
                .flowAppearance()
        }
        .sheet(isPresented: detailSheetPresented) {
            JobDetailSheet(model: model) { id in
                pendingDiskDeleteIDs = [id]
            }
        }
        .confirmationDialog(
            "Remove files?",
            isPresented: Binding(
                get: { !pendingDiskDeleteIDs.isEmpty },
                set: { if !$0 { pendingDiskDeleteIDs = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Files", role: .destructive) {
                let ids = pendingDiskDeleteIDs
                pendingDiskDeleteIDs = []
                Task {
                    for id in ids {
                        await model.remove(jobID: id, deleteFiles: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDiskDeleteIDs = []
            }
        } message: {
            let count = pendingDiskDeleteIDs.count
            if count <= 1 {
                let name = pendingDiskDeleteIDs.first.flatMap { id in
                    model.rows.first(where: { $0.id == id })?.name
                } ?? "this download"
                Text("This permanently deletes “\(name)” from your download folder and removes it from Flow.")
            } else {
                Text(
                    "This permanently deletes \(count) downloads from your download folder and removes them from Flow."
                )
            }
        }
        .confirmationDialog(
            "Clear failed downloads?",
            isPresented: $isClearFailedPresented,
            titleVisibility: .visible
        ) {
            let count = model.rows.count { $0.state == .failed }
            Button(
                count == 1 ? "Clear 1 Download" : "Clear \(count) Downloads",
                role: .destructive
            ) {
                Task { await model.clearFailed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = model.rows.count { $0.state == .failed }
            Text(
                count == 1
                    ? "Removes 1 failed download from Flow. Any partial file it left behind stays on disk."
                    : "Removes \(count) failed downloads from Flow. Any partial files they left behind stay on disk."
            )
        }
        .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
            handleWindowDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(palette.signal, lineWidth: 3)
                    .background(
                        palette.signal.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                    )
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isDropTargeted)
        .task {
            DownloadNotificationCenter.shared.requestAuthorizationIfNeeded()
            launchAgent.attachEngineClient(model.engineClient)
            await launchAgent.ensureRunning()
            // Give launchd a beat to check in the Mach service after bootstrap.
            if launchAgent.isOperational {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            model.startPolling()
            await model.refreshFromEngine()
        }
        .onDisappear {
            model.stopPolling()
        }
    }

    private var librarySurface: some View {
        VStack(spacing: 0) {
            surfaceHeader
            if let error = model.lastErrorMessage {
                libraryErrorBanner(error)
            }
            Group {
                if let reason = model.resolvedEmptyReason(engineReady: launchAgent.isEngineReady) {
                    LibraryEmptyState(
                        reason: reason,
                        onAdd: { model.addSheetPresented = true },
                        onStartEngine: {
                            Task { await launchAgent.repair() }
                        }
                    )
                } else {
                    switch model.layoutMode {
                    case .board:
                        DownloadBoardView(
                            rows: model.visibleRows,
                            selectedID: $model.selectedID,
                            selectedIDs: $model.selectedIDs,
                            onOpenInspector: { id in
                                model.openInspector(for: id)
                            },
                            onCommand: { id, command in
                                Task { await model.control(jobID: id, command: command) }
                            },
                            onRevealInFinder: { id in
                                Task { await model.revealInFinder(jobID: id) }
                            },
                            onOpenFile: { id in
                                Task { await model.openFile(jobID: id) }
                            },
                            onQuickLook: { id in
                                Task { await model.quickLookFile(jobID: id) }
                            },
                            onRemoveFromLibrary: { id in
                                Task { await model.remove(jobID: id, deleteFiles: false) }
                            },
                            onDeleteFromDisk: { id in
                                pendingDiskDeleteIDs = [id]
                            }
                        )
                    case .list:
                        JobTableView(
                            rows: model.visibleRows,
                            selectedID: $model.selectedID,
                            selectedIDs: $model.selectedIDs,
                            onOpenInspector: { id in
                                model.openInspector(for: id)
                            },
                            onCommand: { command in
                                Task { await model.controlSelected(command) }
                            },
                            onRemoveFromList: {
                                Task { await model.removeSelectedTerminal(deleteFiles: false) }
                            },
                            onRemoveFiles: {
                                let ids = Set(model.selectedRows.map(\.id))
                                guard !ids.isEmpty else { return }
                                pendingDiskDeleteIDs = ids
                            },
                            onRevealInFinder: {
                                guard let id = model.selectedID else { return }
                                Task { await model.revealInFinder(jobID: id) }
                            },
                            onOpenFile: {
                                guard let id = model.selectedID else { return }
                                Task { await model.openFile(jobID: id) }
                            }
                        )
                        .padding(12)
                        .background(
                            palette.plateFill,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .accessibilityLabel("Download list")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func libraryErrorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.ember)
            Text(message)
                .font(FlowTheme.Typeface.body(13))
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") {
                model.lastErrorMessage = nil
            }
            .buttonStyle(.plain)
            .font(FlowTheme.Typeface.caption(12))
            .foregroundStyle(palette.inkSoft)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.ember.opacity(0.14))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(message)
    }

    private var surfaceHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(FlowTheme.Typeface.display(28, weight: .heavy))
                    .foregroundStyle(palette.ink)
                Text(headerSubtitle)
                    .font(FlowTheme.Typeface.caption(12))
                    .foregroundStyle(palette.inkSoft)
            }
            Spacer(minLength: 0)
            layoutPicker
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var headerTitle: String {
        switch model.filter {
        case .all: return "All"
        case .active: return "In motion"
        case .queued: return "Waiting"
        case .paused: return "Paused"
        case .completed: return "Finished"
        case .failed: return "Broken"
        case let .category(key): return key.capitalized
        // The filter stores an id; the name lives on the rows. Falling back to
        // the generic word when the last matching row is gone keeps the header
        // honest for the instant before `pruneStaleFilter` resets the selection.
        case let .project(id):
            return model.projectFilters.first { $0.id == id }?.name ?? "Project"
        case let .tag(id):
            return model.tagFilters.first { $0.id == id }?.name ?? "Tag"
        }
    }

    private var headerSubtitle: String {
        let count = model.visibleRows.count
        let noun = count == 1 ? "download" : "downloads"
        return "\(count) \(noun) on the board"
    }

    private var layoutPicker: some View {
        FloatingControlGroup {
            HStack(spacing: 4) {
                ForEach(LibraryLayoutMode.allCases) { mode in
                    Button {
                        model.layoutMode = mode
                    } label: {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(
                                model.layoutMode == mode
                                    ? palette.onSignal
                                    : palette.inkSoft
                            )
                            .frame(width: 34, height: 30)
                            .background {
                                if model.layoutMode == mode {
                                    Capsule().fill(palette.signal)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(mode.title)
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(model.layoutMode == mode ? .isSelected : [])
                }
            }
            .padding(4)
            .floatingControlSurface(in: Capsule())
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
            .help(selectionHelp("Pause"))

            Button {
                Task { await model.controlSelected(.resume) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .disabled(!canResume)
            .help(selectionHelp("Resume"))

            Button {
                Task { await model.controlSelected(.cancel) }
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .disabled(!canCancel)
            .help(selectionHelp("Cancel"))

            Button {
                Task { await model.controlSelected(.retry) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .disabled(!canRetry)
            .help(selectionHelp("Retry"))

            Button {
                Task { await model.controlSelected(.restart) }
            } label: {
                Label("Restart", systemImage: "arrow.counterclockwise")
            }
            .disabled(!canRestart)
            .help(selectionHelp("Restart"))

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

            Menu {
                Button("Remove from List") {
                    Task { await model.removeSelectedTerminal(deleteFiles: false) }
                }
                Button("Remove Files…", role: .destructive) {
                    let ids = Set(model.selectedRows.map(\.id))
                    guard !ids.isEmpty else { return }
                    pendingDiskDeleteIDs = ids
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(!canRemove)
            .accessibilityLabel("Remove selected downloads")
            .help("Remove from list only, or delete the file from disk too")

            Button {
                // Bulk and irreversible — the only remove action that can wipe
                // many rows from one click, so it asks first.
                isClearFailedPresented = true
            } label: {
                Label("Clear Failed", systemImage: "trash.slash")
            }
            .disabled(!hasFailed)
            .accessibilityLabel("Clear Failed")
            .help("Remove all failed downloads from the library (keeps any leftover files)")

            Button {
                model.toggleInspector()
            } label: {
                Label("Details", systemImage: "info.circle")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.inspectedID == nil && model.selectedID == nil)
            .help("Open details for the selected download (or double-click a row)")
        }
    }

    private var selectedStates: [JobState] {
        model.selectedRows.map(\.state)
    }

    private var canPause: Bool {
        BulkJobCommandFilter.anyCanPause(selectedStates)
    }

    private var canResume: Bool {
        BulkJobCommandFilter.anyCanResume(selectedStates)
    }

    private var canCancel: Bool {
        BulkJobCommandFilter.anyCanCancel(selectedStates)
    }

    private var canRetry: Bool {
        BulkJobCommandFilter.anyCanRetry(selectedStates)
    }

    private var canRestart: Bool {
        BulkJobCommandFilter.anyCanRestart(selectedStates)
    }

    private var canRemove: Bool {
        BulkJobCommandFilter.anyCanRemove(selectedStates)
    }

    private var hasFailed: Bool {
        model.rows.contains { DeleteJobGuard.allowsClearFailed($0.state) }
    }

    private func selectionHelp(_ verb: String) -> String {
        let count = model.selectedRows.count
        if count <= 1 {
            return "\(verb) selected download"
        }
        return "\(verb) \(count) selected downloads"
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

/// Brand-forward empty state — Flow is the hero, not a utility caption.
private struct LibraryEmptyState: View {
    let reason: LibraryModel.EmptyReason
    let onAdd: () -> Void
    let onStartEngine: () -> Void
    @Environment(\.flowPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            ZStack {
                Circle()
                    .fill(palette.signal.opacity(glow ? 0.35 : 0.18))
                    .blur(radius: 40)
                    .frame(width: 220, height: 220)
                VStack(spacing: 14) {
                    Text(FlowTheme.brandName)
                        .font(FlowTheme.Typeface.display(56, weight: .heavy))
                        .foregroundStyle(palette.ink)
                    Text(title)
                        .font(FlowTheme.Typeface.title(18))
                        .foregroundStyle(palette.ink)
                    Text(message)
                        .font(FlowTheme.Typeface.body(15))
                        .foregroundStyle(palette.inkSoft)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    if reason == .noDownloads {
                        Button(action: onAdd) {
                            Text("Drop a link in")
                                .font(FlowTheme.Typeface.title(14))
                                .foregroundStyle(palette.onSignal)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(palette.signal, in: Capsule())
                                .shadow(color: palette.signal.opacity(0.45), radius: 16, y: 6)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                        .accessibilityLabel("Add Downloads")
                    } else if reason == .engineUnavailable {
                        Button(action: onStartEngine) {
                            Text("Start Engine")
                                .font(FlowTheme.Typeface.title(14))
                                .foregroundStyle(palette.onSignal)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 12)
                                .background(palette.signal, in: Capsule())
                                .shadow(color: palette.signal.opacity(0.45), radius: 16, y: 6)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                        .accessibilityLabel("Start Engine")
                    }
                }
            }
            Spacer(minLength: 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }

    private var title: String {
        switch reason {
        case .noDownloads: return "Nothing on the board yet"
        case .noMatches: return "Nothing matches"
        case .engineUnavailable: return "Engine isn’t running"
        }
    }

    private var message: String {
        switch reason {
        case .noDownloads:
            return "Paste links, drop a list, or capture from the browser — Flow queues them in the background engine."
        case .noMatches:
            return "Try another filter or clear search to widen the board."
        case .engineUnavailable:
            return "Flow can’t show or start downloads until the transfer engine is up. Click Start Engine to heal it."
        }
    }
}
