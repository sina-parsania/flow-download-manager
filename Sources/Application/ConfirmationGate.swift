// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Decides whether Add/enqueue requires an explicit second confirmation (FR-CAT).
public enum ConfirmationGate {
    /// Confirmation phase for the Add sheet enqueue flow.
    public enum Phase: String, Sendable, Equatable {
        case none
        case needsConfirmation
        case confirmed
    }

    /// True when any classification is low-confidence or falls into `other`.
    public static func shouldConfirm(results: [ClassificationEngine.ClassificationResult]) -> Bool {
        results.contains { $0.confidence == .low || $0.stableKey == "other" }
    }

    /// Category → count summary for the confirmation step, stable-key sorted.
    public static func categoryCounts(
        results: [ClassificationEngine.ClassificationResult]
    ) -> [(stableKey: String, count: Int)] {
        var counts: [String: Int] = [:]
        for result in results {
            counts[result.stableKey, default: 0] += 1
        }
        return counts.keys.sorted().map { key in
            (stableKey: key, count: counts[key] ?? 0)
        }
    }
}
