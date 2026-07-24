// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import SwiftUI
import XPCContracts

/// Compact equal-height download row — one line of controls + metadata.
struct DownloadPinCard: View {
    let row: JobRowModel
    let isSelected: Bool
    let onSelect: () -> Void
    var onOpenInspector: (() -> Void)?
    var onCommand: ((JobCommandKind) -> Void)?
    var onRevealInFinder: (() -> Void)?
    var onRemoveFromLibrary: (() -> Void)?
    var onDeleteFromDisk: (() -> Void)?

    @Environment(\.flowPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var badgeHovered = false

    private var seed: Int {
        row.id.hashValue & 0xFFFF
    }

    private let rowHeight: CGFloat = 64

    var body: some View {
        HStack(spacing: 12) {
            pauseResumeBadgeButton
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(FlowTheme.Typeface.title(13))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.name)
                HStack(spacing: 8) {
                    Text(row.sourceHost)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                    Text("·")
                        .fixedSize()
                    Text(JobRowFormatting.speed(row.speedBytesPerSecond))
                        .lineLimit(1)
                        .fixedSize()
                    if row.state == .downloading {
                        let etaText = JobRowFormatting.eta(row.etaSeconds)
                        if etaText != "—" {
                            Text("·")
                                .fixedSize()
                            Text(etaText)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    Text("·")
                        .fixedSize()
                    Text(row.categoryKey.capitalized)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
                .font(FlowTheme.Typeface.caption(11))
                .foregroundStyle(palette.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            pauseResumeStatusButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.pinSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: FlowTheme.mediaWash(for: row.categoryKey, seed: seed)
                                    .map { $0.opacity(0.22) },
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? palette.signal : palette.pinStroke,
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .shadow(color: palette.ink.opacity(isSelected ? 0.12 : 0.04), radius: isSelected ? 10 : 4, y: 3)
        .opacity(appeared ? 1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(count: 2) {
            onOpenInspector?()
        }
        .onTapGesture(count: 1, perform: onSelect)
        .contextMenu { pinContextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(progressAccessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-click to show details")
        .accessibilityAction(named: "Show Details") {
            onOpenInspector?()
        }
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.easeOut(duration: 0.2)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private var pinContextMenu: some View {
        Button("Pause") { onCommand?(.pause) }
            .disabled(!canPause)
        Button("Resume") { onCommand?(.resume) }
            .disabled(!canResume)
        Button("Cancel") { onCommand?(.cancel) }
            .disabled(!canCancel)
        Divider()
        Button("Retry") { onCommand?(.retry) }
            .disabled(!canRetry)
        Button("Restart") { onCommand?(.restart) }
            .disabled(!canRestart)
        Divider()
        Button("Open in Finder") { onRevealInFinder?() }
        Divider()
        Button("Remove from List") { onRemoveFromLibrary?() }
            .disabled(onRemoveFromLibrary == nil)
        Button("Remove Files…", role: .destructive) { onDeleteFromDisk?() }
            .disabled(onDeleteFromDisk == nil)
    }

    private var pauseResumeStatusButton: some View {
        Button(action: togglePauseResume) {
            HStack(spacing: 5) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(row.state.shortLabel)
                    .font(FlowTheme.Typeface.caption(10))
                    .tracking(0.6)
                    .lineLimit(1)
            }
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(palette.chipFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canTogglePauseResume)
        .help(toggleHelp)
        .accessibilityLabel(toggleAccessibilityLabel)
        .accessibilityValue(row.state.displayName)
    }

    private var pauseResumeBadgeButton: some View {
        Button(action: togglePauseResume) {
            downieProgressBadge
        }
        .buttonStyle(.plain)
        .disabled(!canTogglePauseResume)
        .help(toggleHelp)
        .accessibilityLabel(toggleAccessibilityLabel)
        .accessibilityValue(progressAccessibilityValue)
    }

    private var downieProgressBadge: some View {
        let fraction = row.progressFraction.map { max(0, min(1, $0)) }
        return ZStack {
            Circle()
                .stroke(palette.ink.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction ?? (row.statusRole == .success ? 1 : 0))
                .stroke(
                    AngularGradient(
                        colors: [palette.signal, palette.signalDeep, palette.signal],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            badgeCenter(fraction: fraction)
        }
        .frame(width: 34, height: 34)
        .contentShape(Circle())
        .onHover { hovering in
            badgeHovered = hovering
        }
    }

    /// The percentage owns the badge centre whenever a fraction is known, so an
    /// active download always shows a number. The pause/play glyph takes over only
    /// while the pointer is on the badge; it also lives permanently in the status
    /// chip and the context menu, so the affordance never depends on hover alone.
    @ViewBuilder
    private func badgeCenter(fraction: Double?) -> some View {
        if let fraction, !(badgeHovered && canTogglePauseResume) {
            Text(JobRowFormatting.percentText(fraction: fraction))
                .font(FlowTheme.Typeface.mono(9))
                .foregroundStyle(palette.ink)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        } else if canResume {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink)
                .offset(x: 1)
        } else if canPause {
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.ink)
        } else {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink)
        }
    }

    private func togglePauseResume() {
        if canResume {
            onCommand?(.resume)
        } else if canPause {
            onCommand?(.pause)
        }
    }

    private var canTogglePauseResume: Bool {
        canPause || canResume
    }

    private var toggleHelp: String {
        if canResume { return "Resume download" }
        if canPause { return "Pause download" }
        return "Download control"
    }

    private var toggleAccessibilityLabel: String {
        if canResume { return "Resume" }
        if canPause { return "Pause" }
        return row.state.displayName
    }

    /// Live quantity for VoiceOver. Kept out of the label so the announcement is a
    /// changing *value* on a stable control rather than a renamed button.
    private var progressAccessibilityValue: String {
        guard let fraction = row.progressFraction else { return "Progress unknown" }
        return JobRowFormatting.percentText(fraction: fraction)
    }

    private var statusSymbol: String {
        switch row.statusRole {
        case .active: return "bolt.fill"
        case .queued: return "hourglass"
        case .paused: return "pause.fill"
        case .success: return "checkmark"
        case .failure: return "exclamationmark"
        }
    }

    private var canPause: Bool {
        BulkJobCommandFilter.canPause(row.state)
    }

    private var canResume: Bool {
        BulkJobCommandFilter.canResume(row.state)
    }

    private var canCancel: Bool {
        BulkJobCommandFilter.canCancel(row.state)
    }

    private var canRetry: Bool {
        BulkJobCommandFilter.canRetry(row.state)
    }

    private var canRestart: Bool {
        BulkJobCommandFilter.canRestart(row.state)
    }

    private var accessibilitySummary: String {
        "\(row.name), \(row.state.displayName), from \(row.sourceHost)"
    }
}
