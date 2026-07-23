// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import SwiftUI
import UniformTypeIdentifiers
import XPCContracts

/// Main library window: editorial sidebar + Pinterest board (or dense list) + inspector.
public struct RootView: View {
    @ObservedObject private var model: LibraryModel
    @ObservedObject private var launchAgent: LaunchAgentModel
    @State private var isDropTargeted = false
    @State private var pendingDiskDeleteID: JobRowModel.ID?
    @Environment(\.flowPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: LibraryModel, launchAgent: LaunchAgentModel) {
        self.model = model
        self.launchAgent = launchAgent
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
                            },
                            onRevealInFinder: {
                                guard let id = model.selectedID else { return }
                                Task { await model.revealInFinder(jobID: id) }
                            },
                            onRemoveFromLibrary: {
                                guard let id = model.selectedID else { return }
                                Task { await model.remove(jobID: id, deleteFiles: false) }
                            },
                            onDeleteFromDisk: {
                                guard let id = model.selectedID else { return }
                                pendingDiskDeleteID = id
                            }
                        )
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                    }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .sheet(isPresented: $model.addSheetPresented) {
            AddDownloadsSheet()
                .environmentObject(model)
                .environmentObject(launchAgent)
                .flowAppearance()
        }
        .confirmationDialog(
            "Delete from disk?",
            isPresented: Binding(
                get: { pendingDiskDeleteID != nil },
                set: { if !$0 { pendingDiskDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete File & Remove", role: .destructive) {
                guard let id = pendingDiskDeleteID else { return }
                pendingDiskDeleteID = nil
                Task { await model.remove(jobID: id, deleteFiles: true) }
            }
            Button("Cancel", role: .cancel) {
                pendingDiskDeleteID = nil
            }
        } message: {
            let name = pendingDiskDeleteID.flatMap { id in
                model.rows.first(where: { $0.id == id })?.name
            } ?? "this download"
            Text("This permanently deletes “\(name)” from your download folder and removes it from Flow.")
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
            Group {
                if let reason = model.emptyReason {
                    LibraryEmptyState(reason: reason) { model.addSheetPresented = true }
                } else {
                    switch model.layoutMode {
                    case .board:
                        DownloadBoardView(
                            rows: model.visibleRows,
                            selectedID: $model.selectedID,
                            onCommand: { id, command in
                                Task { await model.control(jobID: id, command: command) }
                            },
                            onRevealInFinder: { id in
                                Task { await model.revealInFinder(jobID: id) }
                            },
                            onRemoveFromLibrary: { id in
                                Task { await model.remove(jobID: id, deleteFiles: false) }
                            },
                            onDeleteFromDisk: { id in
                                pendingDiskDeleteID = id
                            }
                        )
                    case .list:
                        JobTableView(rows: model.visibleRows, selectedID: $model.selectedID)
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

            Menu {
                Button("Remove from Library") {
                    Task { await model.removeSelectedTerminal(deleteFiles: false) }
                }
                Button("Delete File & Remove…", role: .destructive) {
                    guard let id = model.selectedID else { return }
                    pendingDiskDeleteID = id
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(!canRemove)
            .accessibilityLabel("Remove selected download")
            .help("Remove from library only, or delete the file from disk too")

            Button {
                Task { await model.clearFailed() }
            } label: {
                Label("Clear Failed", systemImage: "trash.slash")
            }
            .disabled(!hasFailed)
            .accessibilityLabel("Clear Failed")
            .help("Remove all failed downloads from the library (keeps any leftover files)")

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

/// Brand-forward empty state — Flow is the hero, not a utility caption.
private struct LibraryEmptyState: View {
    let reason: LibraryModel.EmptyReason
    let onAdd: () -> Void
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
        reason == .noDownloads ? "Nothing on the board yet" : "Nothing matches"
    }

    private var message: String {
        reason == .noDownloads
            ? "Paste links, drop a list, or capture from the browser — Flow queues them in the background engine."
            : "Try another filter or clear search to widen the board."
    }
}
