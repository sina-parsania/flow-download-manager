// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Editorial filter rail — brand mark + status + quiet filter chips.
struct SidebarView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var launchAgent: LaunchAgentModel
    @Environment(\.flowPalette) private var palette

    private static let categories = ["videos", "audio", "images", "documents", "archives"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    engineBlock
                    filterBlock(
                        title: "Library",
                        items: [
                            (.all, "All", "tray.full"),
                            (.active, "Active", "bolt.fill"),
                            (.queued, "Queued", "hourglass"),
                            (.paused, "Paused", "pause.fill"),
                            (.completed, "Done", "checkmark"),
                            (.failed, "Failed", "exclamationmark")
                        ]
                    )
                    filterBlock(
                        title: "Categories",
                        items: Self.categories.map { key in
                            (.category(key), key.capitalized, symbol(for: key))
                        }
                    )
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .background(Color.clear)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(FlowTheme.brandName)
                .font(FlowTheme.Typeface.display(34, weight: .heavy))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text("downloads, composed")
                .font(FlowTheme.Typeface.caption(11))
                .foregroundStyle(palette.inkSoft)
                .tracking(0.6)
        }
    }

    private var engineBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Engine")
            EngineStatusBadge(model: launchAgent)
        }
    }

    private func filterBlock(
        title: String,
        items: [(LibraryFilter, String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(title)
            VStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    filterChip(item.0, item.1, item.2)
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(FlowTheme.Typeface.caption(10))
            .tracking(1.4)
            .foregroundStyle(palette.inkSoft)
            .padding(.leading, 8)
    }

    private func filterChip(_ filter: LibraryFilter, _ title: String, _ symbol: String) -> some View {
        let selected = model.filter == filter
        return Button {
            model.filter = filter
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(FlowTheme.Typeface.body(13))
                Spacer(minLength: 0)
                if selected {
                    Circle()
                        .fill(palette.signal)
                        .frame(width: 7, height: 7)
                        .shadow(color: palette.signal.opacity(0.7), radius: 4)
                }
            }
            .foregroundStyle(selected ? palette.ink : palette.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.chipFill)
                        .shadow(color: palette.ink.opacity(palette.isDark ? 0.25 : 0.06), radius: 8, y: 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

/// Compact engine badge; taps open registration controls.
private struct EngineStatusBadge: View {
    @ObservedObject var model: LaunchAgentModel
    @Environment(\.flowPalette) private var palette
    @State private var showControls = false

    var body: some View {
        Button {
            showControls = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(model.isOperational
                            ? palette.signal.opacity(0.35)
                            : palette.chipFill)
                        .frame(width: 28, height: 28)
                    Image(systemName: model.isOperational ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.ink)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.isOperational ? "Engine on" : model.status.headline)
                        .font(FlowTheme.Typeface.body(12))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Text(model.isOperational
                        ? (model.runtimeMode == .directChild
                            ? "always on · in-app"
                            : model.runtimeMode == .legacyLaunchd ? "always on · local" : "always on")
                        : model.status.badgeSubtitle)
                        .font(FlowTheme.Typeface.caption(10))
                        .foregroundStyle(palette.inkSoft)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(palette.chipFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
