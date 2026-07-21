// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Sidebar: background-engine status, Library (status) filters and Categories
/// (`03-design-system-ui-ux.md` §2, §3). Category/project/tag are independent
/// filters; a category never implies a folder tree.
struct SidebarView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var launchAgent: LaunchAgentModel

    private static let categories = ["videos", "audio", "images", "documents", "archives"]

    var body: some View {
        List(selection: Binding(
            get: { model.filter },
            set: { model.filter = $0 ?? .all }
        )) {
            Section("Engine") {
                EngineStatusBadge(model: launchAgent)
            }

            Section("Library") {
                filterRow(.all, "All Downloads", "tray.full")
                filterRow(.active, "Active", "arrow.down.circle")
                filterRow(.queued, "Queued", "clock")
                filterRow(.paused, "Paused", "pause.circle")
                filterRow(.completed, "Completed", "checkmark.circle")
                filterRow(.failed, "Failed", "exclamationmark.triangle")
            }

            Section("Categories") {
                ForEach(Self.categories, id: \.self) { key in
                    filterRow(.category(key), key.capitalized, symbol(for: key))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func filterRow(_ filter: LibraryFilter, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .tag(filter)
            .accessibilityLabel(title)
    }

    private func symbol(for category: String) -> String {
        switch category {
        case "videos": return "film"
        case "audio": return "music.note"
        case "images": return "photo"
        case "documents": return "doc"
        case "archives": return "archivebox"
        default: return "folder"
        }
    }
}

/// Compact engine badge in the sidebar; taps route to the full status/registration
/// controls. Colour is supplemental to the symbol + text.
private struct EngineStatusBadge: View {
    @ObservedObject var model: LaunchAgentModel
    @State private var showControls = false

    var body: some View {
        Button {
            showControls = true
        } label: {
            Label {
                Text(model.status.headline).lineLimit(1)
            } icon: {
                Image(systemName: model.status.isOperational ? "bolt.circle.fill" : "bolt.slash.circle")
                    .foregroundStyle(model.status.isOperational ? Color.green : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Background engine: \(model.status.headline)")
        .popover(isPresented: $showControls) {
            EngineStatusView(model: model)
                .frame(width: 320, height: 220)
        }
        .onAppear { model.refresh() }
    }
}
