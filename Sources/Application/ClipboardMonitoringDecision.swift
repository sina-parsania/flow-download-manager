// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Pure clipboard-change decision for FR-ING opt-in monitoring (no AppKit).
public enum ClipboardMonitoringDecision {
    /// Returns true when `newText` differs from `previousText` and contains at
    /// least one Phase-1-valid URL. Never enqueues — callers only notify / prefill.
    public static func shouldNotify(previousText: String?, newText: String) -> Bool {
        guard newText != previousText else { return false }
        return URLTextExtractor.extract(from: newText).validCount > 0
    }
}
