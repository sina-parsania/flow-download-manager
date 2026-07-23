// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import XPCContracts

/// Shared default-folder control for Compose and Settings.
struct DestinationFolderCard: View {
    let engineClient: EngineClient
    var compact: Bool = false
    var onChanged: (() -> Void)?
    /// When XPC is dead, heal launchd (unregister broken SM → legacy) then retry.
    var onHealEngine: (() async -> Bool)?

    @Environment(\.flowPalette) private var palette
    @State private var destination: DefaultDestinationSnapshot = Self.fallbackSnapshot()
    @State private var statusMessage: String?
    @State private var isBusy = false
    @State private var engineReachable = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            if !compact {
                Text("SAVE TO")
                    .font(FlowTheme.Typeface.caption(10))
                    .tracking(1.3)
                    .foregroundStyle(palette.inkSoft)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(palette.signal.opacity(0.22))
                            .frame(width: 40, height: 40)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.onSignal)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(destination.folderName)
                            .font(FlowTheme.Typeface.title(14))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                        Text(shortenedPath(destination.pathDisplay))
                            .font(FlowTheme.Typeface.caption(12))
                            .foregroundStyle(palette.inkSoft)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Text(badgeLabel)
                            .font(FlowTheme.Typeface.caption(11))
                            .foregroundStyle(palette.inkSoft.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button {
                        chooseFolder()
                    } label: {
                        Text(isBusy ? "Saving…" : "Choose folder…")
                            .font(FlowTheme.Typeface.body(13))
                            .foregroundStyle(palette.onSignal)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(palette.signal, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .accessibilityLabel("Choose download folder")

                    if !destination.isDefaultDownloads {
                        Button {
                            Task { await resetFolder() }
                        } label: {
                            Text("Use default")
                                .font(FlowTheme.Typeface.body(13))
                                .foregroundStyle(palette.ink)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(palette.chipFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                        .accessibilityLabel("Use default Downloads folder")
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(FlowTheme.Typeface.caption(12))
                        .foregroundStyle(engineReachable ? palette.inkSoft : palette.ember)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(palette.pinSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.pinStroke, lineWidth: 1)
            }
        }
        .task {
            await reload(allowHeal: true)
        }
    }

    private var badgeLabel: String {
        if destination.isDefaultDownloads {
            return engineReachable
                ? "Default · Downloads/DownloadManager"
                : "Default path · engine not answering"
        }
        return engineReachable
            ? "Custom folder"
            : "Custom path · engine not answering"
    }

    private func shortenedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func fallbackSnapshot() -> DefaultDestinationSnapshot {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let url = downloads.appendingPathComponent("DownloadManager", isDirectory: true)
        return DefaultDestinationSnapshot(
            pathDisplay: url.path,
            folderName: "DownloadManager",
            isDefaultDownloads: true
        )
    }

    @MainActor
    private func reload(allowHeal: Bool) async {
        switch await race(seconds: 5, {
            try await engineClient.getDefaultDestination()
        }) {
        case let .ok(value):
            destination = value
            engineReachable = true
            statusMessage = nil
        case .timeout, .failed:
            if allowHeal, let onHealEngine {
                statusMessage = "Starting engine…"
                engineReachable = false
                let healed = await onHealEngine()
                if healed {
                    await reload(allowHeal: false)
                    return
                }
            }
            engineReachable = false
            destination = Self.fallbackSnapshot()
            statusMessage = "Engine not answering yet. Wait a second, or open the engine badge → Repair."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "New downloads will be saved in this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // Plain bookmark — agent binary cannot reliably resolve app security-scoped bookmarks.
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            Task { await applyBookmark(bookmark, displayName: url.lastPathComponent, localURL: url) }
        } catch {
            statusMessage = "Could not remember that folder."
        }
    }

    @MainActor
    private func applyBookmark(_ bookmark: Data, displayName: String, localURL: URL) async {
        guard !isBusy else { return }
        isBusy = true
        destination = DefaultDestinationSnapshot(
            pathDisplay: localURL.path,
            folderName: displayName,
            isDefaultDownloads: false
        )

        let result = await race(seconds: 10) {
            try await engineClient.setDefaultDestination(
                bookmarkData: bookmark,
                displayName: displayName,
                pathDisplay: localURL.path
            )
        }
        isBusy = false

        switch result {
        case let .ok(value):
            destination = value
            engineReachable = true
            statusMessage = "Saved as the default download folder."
            onChanged?()
        case .timeout, .failed:
            engineReachable = false
            statusMessage =
                "Could not save folder to engine. Open the engine badge → Repair, then Choose again."
        }
    }

    @MainActor
    private func resetFolder() async {
        guard !isBusy else { return }
        isBusy = true
        let result = await race(seconds: 10) {
            try await engineClient.setDefaultDestination(
                bookmarkData: nil,
                displayName: nil,
                pathDisplay: nil
            )
        }
        isBusy = false

        switch result {
        case let .ok(value):
            destination = value
            engineReachable = true
            statusMessage = "Reset to Downloads/DownloadManager."
            onChanged?()
        case .timeout, .failed:
            engineReachable = false
            destination = Self.fallbackSnapshot()
            statusMessage = "Could not reset — engine not answering."
        }
    }

    private enum RaceResult<T: Sendable>: Sendable {
        case ok(T)
        case timeout
        case failed
    }

    /// First finished wins. Timeout does not wait for hung XPC.
    private func race<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> RaceResult<T> {
        await withTaskGroup(of: RaceResult<T>.self) { group in
            group.addTask {
                do {
                    return try await .ok(operation())
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
    }
}
