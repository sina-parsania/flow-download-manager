// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import SwiftUI
import XPCContracts

/// Compact equal-height download row — one line of controls + metadata.
struct DownloadPinCard: View {
    let row: JobRowModel
    let isSelected: Bool
    let onSelect: () -> Void
    var onCommand: ((JobCommandKind) -> Void)?
    var onRevealInFinder: (() -> Void)?
    var onRemoveFromLibrary: (() -> Void)?
    var onDeleteFromDisk: (() -> Void)?

    @Environment(\.flowPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

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
                HStack(spacing: 8) {
                    Text(row.sourceHost)
                        .lineLimit(1)
                    Text("·")
                    Text(JobRowFormatting.speed(row.speedBytesPerSecond))
                    if row.state == .downloading {
                        let etaText = JobRowFormatting.eta(row.etaSeconds)
                        if etaText != "—" {
                            Text("·")
                            Text(etaText)
                        }
                    }
                    Text("·")
                    Text(row.categoryKey.capitalized)
                }
                .font(FlowTheme.Typeface.caption(11))
                .foregroundStyle(palette.inkSoft)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
        .onTapGesture(perform: onSelect)
        .contextMenu { pinContextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        Divider()
        Button("Retry") { onCommand?(.retry) }
            .disabled(!canRetry)
        Button("Restart") { onCommand?(.restart) }
            .disabled(!canRestart)
        Divider()
        Button("Open in Finder") { onRevealInFinder?() }
        if canRemove {
            Divider()
            Button("Remove from Library") { onRemoveFromLibrary?() }
            Button("Delete File & Remove…", role: .destructive) { onDeleteFromDisk?() }
        }
    }

    private var pauseResumeStatusButton: some View {
        Button(action: togglePauseResume) {
            HStack(spacing: 5) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(shortStateLabel)
                    .font(FlowTheme.Typeface.caption(10))
                    .tracking(0.6)
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
    }

    private var pauseResumeBadgeButton: some View {
        Button(action: togglePauseResume) {
            downieProgressBadge
        }
        .buttonStyle(.plain)
        .disabled(!canTogglePauseResume)
        .help(toggleHelp)
        .accessibilityLabel(toggleAccessibilityLabel)
    }

    private var downieProgressBadge: some View {
        let fraction = row.progressFraction.map { max(0, min(1, $0)) }
        let showPercent = row.statusRole == .active || row.statusRole == .success
            || (fraction ?? 0) > 0
        return ZStack {
            Circle()
                .stroke(palette.ink.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction ?? (row.statusRole == .success ? 1 : 0))
                .stroke(
                    palette.signal,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            if canResume {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .offset(x: 1)
            } else if canPause {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.ink)
            } else if showPercent, let fraction {
                Text(JobRowFormatting.percentText(fraction: fraction))
                    .font(FlowTheme.Typeface.mono(9))
                    .foregroundStyle(palette.ink)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.ink)
            }
        }
        .frame(width: 34, height: 34)
        .contentShape(Circle())
    }

    private var shortStateLabel: String {
        switch row.state {
        case .downloading: return "LIVE"
        case .paused: return "PAUSED"
        case .queued, .ready, .scheduled: return "QUEUE"
        case .completed: return "DONE"
        case .failed: return "FAIL"
        case .cancelled: return "STOP"
        default: return row.state.rawValue.uppercased()
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
        return row.state.rawValue
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
        switch row.state {
        case .downloading, .connecting, .queued, .ready, .verifying, .merging, .postProcessing:
            return true
        default:
            return false
        }
    }

    private var canResume: Bool {
        row.state == .paused || row.state == .retryWaiting
    }

    private var canRetry: Bool {
        row.state == .failed || row.state == .cancelled
    }

    private var canRestart: Bool {
        row.state == .paused || row.state == .failed || row.state == .cancelled
    }

    private var canRemove: Bool {
        row.state == .completed || row.state == .failed || row.state == .cancelled
    }

    private var accessibilitySummary: String {
        let pct = JobRowFormatting.percentText(fraction: row.progressFraction)
        return "\(row.name), \(row.state.rawValue), from \(row.sourceHost), \(pct)"
    }
}
