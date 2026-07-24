// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Unified Logging for the Chrome Native Messaging host.
///
/// Mirrors `EngineLog.browserExtension`'s subsystem and category without pulling
/// `SharedObservability` into this module's dependency graph. Only fixed,
/// non-sensitive text is ever interpolated here: URLs, header names and header
/// values from the extension must not reach a log line.
enum NativeHostLog {
    static let host = Logger(subsystem: "org.downloadmanager.local", category: "extension")
}
