// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import Foundation
import XPCContracts

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
    @Published public var pendingClipboardText: String?
    @Published public var lastErrorMessage: String?

    public let engineClient: EngineClient
    private var refreshTask: Task<Void, Never>?
    private var knownCompleted: Set<UUID> = []

    public init(rows: [JobRowModel], engineClient: EngineClient = EngineClient()) {
        self.rows = rows
        self.engineClient = engineClient
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

    public func presentClipboardLinks(_ text: String) {
        pendingClipboardText = text
        addSheetPresented = true
    }

    public func presentOpenURLLinks(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        presentClipboardLinks(urls.joined(separator: "\n"))
    }

    public func handleOpenURL(_ url: URL) {
        if url.isFileURL {
            handleDroppedFileURL(url)
            return
        }
        presentOpenURLLinks(OpenURLIngest.parse(url))
    }

    /// Prefills Add from a Finder/dock file open or a window drop (txt/csv).
    public func handleDroppedFileURL(_ url: URL) {
        do {
            let text = try ImportTextIngest.readText(from: url)
            presentClipboardLinks(text)
        } catch {
            lastErrorMessage = "Could not import the dropped file."
        }
    }

    /// Prefills Add from plain-text drops onto the library window.
    public func handleDroppedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presentClipboardLinks(trimmed)
    }

    public func controlSelected(_ command: JobCommandKind) async {
        guard let row = selectedRow else { return }
        do {
            _ = try await engineClient.controlJob(jobID: row.id.uuidString.lowercased(), command: command)
            await refreshFromEngine()
        } catch {
            lastErrorMessage = "Could not \(String(describing: command)) the selected download."
        }
    }

    public func pauseAll() async {
        let targets = rows.filter { BulkJobCommandFilter.shouldReceivePause($0.state) }
        for row in targets {
            do {
                _ = try await engineClient.controlJob(
                    jobID: row.id.uuidString.lowercased(),
                    command: .pause
                )
            } catch {
                lastErrorMessage = "Could not pause all downloads."
            }
        }
        await refreshFromEngine()
    }

    public func resumeAll() async {
        let targets = rows.filter { BulkJobCommandFilter.shouldReceiveResume($0.state) }
        for row in targets {
            do {
                _ = try await engineClient.controlJob(
                    jobID: row.id.uuidString.lowercased(),
                    command: .resume
                )
            } catch {
                lastErrorMessage = "Could not resume all downloads."
            }
        }
        await refreshFromEngine()
    }

    public func bumpSelectedPriority(by delta: Int) async {
        guard let row = selectedRow else { return }
        let next = row.priority + delta
        do {
            _ = try await engineClient.setJobPriority(
                jobID: row.id.uuidString.lowercased(),
                priority: next
            )
            await refreshFromEngine()
        } catch {
            lastErrorMessage = "Could not change priority."
        }
    }

    public func removeSelectedTerminal() async {
        guard let row = selectedRow, DeleteJobGuard.allowsDelete(row.state) else { return }
        do {
            _ = try await engineClient.deleteJob(jobID: row.id.uuidString.lowercased())
            if selectedID == row.id { selectedID = nil }
            await refreshFromEngine()
        } catch {
            lastErrorMessage = "Could not remove the selected download."
        }
    }

    public func clearFailed() async {
        let targets = rows.filter { DeleteJobGuard.allowsClearFailed($0.state) }
        let removedIDs = Set(targets.map(\.id))
        for row in targets {
            do {
                _ = try await engineClient.deleteJob(jobID: row.id.uuidString.lowercased())
            } catch {
                lastErrorMessage = "Could not clear all failed downloads."
            }
        }
        if let selectedID, removedIDs.contains(selectedID) {
            self.selectedID = nil
        }
        await refreshFromEngine()
    }

    public func startPolling() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFromEngine()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func refreshFromEngine(using client: EngineClient? = nil) async {
        let client = client ?? engineClient
        do {
            let snapshot = try await client.listJobs()
            let mapped: [JobRowModel] = snapshot.jobs.compactMap { job in
                guard let id = UUID(uuidString: job.id),
                      let state = JobState(rawValue: job.state)
                else { return nil }
                return JobRowModel(
                    id: id,
                    name: job.name,
                    sourceHost: job.sourceHost,
                    state: state,
                    progressFraction: job.hasProgress ? job.progressFraction : nil,
                    bytesTransferred: job.bytesTransferred,
                    totalBytes: job.hasTotalBytes ? job.totalBytes : nil,
                    speedBytesPerSecond: job.speedBytesPerSecond,
                    etaSeconds: nil,
                    categoryKey: job.categoryKey,
                    projectID: job.projectID,
                    projectName: job.projectName,
                    tagIDs: job.tagIDs,
                    tagNames: job.tagNames,
                    priority: job.priority
                )
            }
            notifyTerminalTransitions(from: rows, to: mapped)
            rows = mapped
            lastErrorMessage = nil
        } catch {
            // Keep existing rows when the engine is unavailable (ad-hoc / not registered).
        }
    }

    private func notifyTerminalTransitions(from oldRows: [JobRowModel], to newRows: [JobRowModel]) {
        let oldByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
        for row in newRows {
            let previous = oldByID[row.id]
            if row.state == .completed, previous?.state != .completed, !knownCompleted.contains(row.id) {
                knownCompleted.insert(row.id)
                DownloadNotificationCenter.shared.postJobFinished(name: row.name, succeeded: true)
            } else if row.state == .failed, previous?.state != .failed {
                DownloadNotificationCenter.shared.postJobFinished(name: row.name, succeeded: false)
            }
        }
    }
}
