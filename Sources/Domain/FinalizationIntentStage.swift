// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Durable stage of a crash-recoverable finalization intent.
///
/// `prepared` is written before any filesystem promotion; `promoted` is written
/// after the partial has been atomically renamed to its final relative name.
public enum FinalizationIntentStage: String, CaseIterable, Sendable, Codable {
    case prepared
    case promoted
}
