// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Presentation formatting for byte counts, rates and durations. Uses byte/rate
/// formatters and produces strings suitable for monospaced-digit columns
/// (`03-design-system-ui-ux.md` §10). Main-actor isolated: it is used only from
/// UI (table cells, inspector), which lets the shared `ByteCountFormatter` be
/// cached without violating Swift 6 concurrency.
@MainActor
public enum JobRowFormatting {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    public static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return byteFormatter.string(fromByteCount: bytes)
    }

    public static func progressText(fraction: Double?, transferred: Int64, total: Int64?) -> String {
        let sizePart = "\(byteFormatter.string(fromByteCount: transferred)) / \(size(total))"
        guard let fraction else { return sizePart }
        let pct = Int((fraction * 100).rounded())
        return "\(pct)% · \(sizePart)"
    }

    public static func speed(_ bytesPerSecond: Int64) -> String {
        guard bytesPerSecond > 0 else { return "—" }
        return "\(byteFormatter.string(fromByteCount: bytesPerSecond))/s"
    }

    public static func eta(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
