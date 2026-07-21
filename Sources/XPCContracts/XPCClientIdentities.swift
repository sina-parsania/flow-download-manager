// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Code-signing identifiers permitted to connect to the engine's XPC listener.
///
/// These are owner-supplied local development identifiers (see
/// `Configuration/BundleIdentifiers.xcconfig`) and must be replaced with the
/// release owner's signed identifiers before public distribution. The agent's
/// `CodeSigningIdentityValidator` requires the connecting peer's signing
/// identifier to be one of these; nothing else is authorized.
public enum XPCClientIdentities {
    public static let appBundleIdentifier = "org.downloadmanager.local.DownloadManager"

    /// The signed native messaging host, authorized from Phase 2 onward. Declared
    /// for a single source of truth; it has no shipping surface in Phase 0.
    public static let nativeHostBundleIdentifier = "org.downloadmanager.local.ChromeNativeHost"
}
