// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Unified Logging categories and redaction primitives (`02-architecture.md` §16,
/// `06-licensing-security-privacy.md` §4).
///
/// URLs, paths, headers, cookies and credentials must be redacted *at the
/// interpolation source*: interpolate dynamic strings with `privacy: .private`
/// (the default) or pass values already reduced by the helpers here. The static
/// message text and explicitly-public, non-sensitive values may use
/// `privacy: .public`.
public enum EngineLog {
    public static let subsystem = "org.downloadmanager.local"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let xpc = Logger(subsystem: subsystem, category: "xpc")
    public static let ingestion = Logger(subsystem: subsystem, category: "ingestion")
    public static let scheduler = Logger(subsystem: subsystem, category: "scheduler")
    public static let transfer = Logger(subsystem: subsystem, category: "transfer")
    public static let filesystem = Logger(subsystem: subsystem, category: "filesystem")
    public static let media = Logger(subsystem: subsystem, category: "media")
    public static let torrent = Logger(subsystem: subsystem, category: "torrent")
    public static let browserExtension = Logger(subsystem: subsystem, category: "extension")
    public static let updater = Logger(subsystem: subsystem, category: "updater")

    /// The agent process logs under the `app`-adjacent `agent` category.
    public static let agent = Logger(subsystem: subsystem, category: "agent")

    /// Reduce an error to a non-sensitive, stable string safe for logs and
    /// diagnostic export. For `NSError` this is `domain#code`; `userInfo` (which
    /// may carry paths/URLs) is deliberately dropped. Other errors reduce to their
    /// type name.
    public static func redacted(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code)"
    }

    /// Reduce a URL to `scheme + registrable-host` only; path and query are
    /// dropped (`02-architecture.md` §16). Returns `"<invalid-url>"` for
    /// unparseable input rather than echoing it.
    public static func redacted(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host() else { return "<invalid-url>" }
        return "\(scheme)://\(host)"
    }
}
