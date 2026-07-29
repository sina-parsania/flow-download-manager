// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Finds the yt-dlp helper on this machine.
///
/// `vendorMediaExecutable` resolved its candidate from
/// `FileManager.currentDirectoryPath`, which is the repo root only when the
/// binary was launched from a shell inside the repo. A GUI-launched macOS app
/// has a working directory of `/`, so the candidate was literally
/// `/VendorBuild/prefix/arm64/media/bin/yt-dlp` and every released build
/// resolved `nil` — leaving the probe button permanently disabled and the whole
/// media chain unreachable.
///
/// **Provenance is the security property here.** This type decides which binary
/// Flow executes, so where a path came from matters more than whether it
/// exists. Only two sources are trusted: a path inside Flow's own bundle, and a
/// path the user chose in an open panel. Auto-discovery is a convenience over
/// well-known package-manager locations and is permission-checked; nothing else
/// may write ``userChosenPathDefaultsKey``.
public enum MediaHelperLocator {
    /// Where a resolved helper came from. Surfaced so the UI can name the path
    /// before the user runs it — an executable that appeared by magic is exactly
    /// what a user should be able to inspect.
    public enum Source: Equatable, Sendable {
        case bundled
        case userChosen
        case discovered
    }

    public struct Resolved: Equatable, Sendable {
        public let url: URL
        public let source: Source

        public init(url: URL, source: Source) {
            self.url = url
            self.source = source
        }
    }

    /// The user-chosen helper path. Written by exactly ONE code path — the open
    /// panel in Settings. It must never be written from the native messaging
    /// host, the clipboard monitor, a dropped file, a URL, or any XPC payload:
    /// Flow already accepts external input on a native messaging channel, so
    /// this is a live surface, not a hypothetical one.
    public static let userChosenPathDefaultsKey = "media.ytdlpPath"

    /// Well-known package-manager locations, in preference order. `/opt/homebrew`
    /// is the arm64 Homebrew prefix and is root-owned on a normal install.
    ///
    /// `/usr/local/bin` is deliberately included but is the riskiest entry: on a
    /// migrated or hand-managed Mac it is frequently user-writable, which would
    /// let any local process drop a file named `yt-dlp` that Flow later executes.
    /// ``isSafeToExecute`` is what makes it acceptable.
    private static let discoveryDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin"
    ]

    /// Resolves the helper, preferring the most trustworthy source.
    ///
    /// Order is bundled → user-chosen → discovered, so a binary Flow shipped
    /// always wins over one found on the system, and an explicit user choice
    /// wins over a guess.
    public static func resolve(
        name: String = "yt-dlp",
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Resolved? {
        if let bundled = bundledExecutable(named: name, bundle: bundle, fileManager: fileManager) {
            return Resolved(url: bundled, source: .bundled)
        }
        if let chosen = userChosenExecutable(defaults: defaults, fileManager: fileManager) {
            return Resolved(url: chosen, source: .userChosen)
        }
        if let found = discoveredExecutable(named: name, fileManager: fileManager) {
            return Resolved(url: found, source: .discovered)
        }
        return nil
    }

    /// A helper shipped inside Flow.app. Nothing bundles one today — the
    /// VendorBuild manifest still has a null download URL — but resolution has to
    /// prefer it so that bundling later needs no change here.
    public static func bundledExecutable(
        named name: String,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let candidate = resourceURL
            .appendingPathComponent("MediaHelpers", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        guard fileManager.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// The path the user picked, if it is still executable. A helper that was
    /// moved or uninstalled resolves to `nil` rather than to a stale path.
    public static func userChosenExecutable(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let path = defaults.string(forKey: userChosenPathDefaultsKey),
              !path.isEmpty,
              fileManager.isExecutableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static func discoveredExecutable(
        named name: String,
        fileManager: FileManager = .default
    ) -> URL? {
        for directory in discoveryDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            guard isSafeToExecute(candidate, fileManager: fileManager) else { continue }
            return candidate
        }
        return nil
    }

    /// Rejects an auto-discovered binary that any local user could have replaced.
    ///
    /// Checks the file AND its parent directory: a group- or world-writable
    /// directory lets an attacker swap the binary even when the binary itself is
    /// root-owned and read-only. Applies only to discovery — a bundled helper
    /// ships with Flow, and a user-chosen one was named deliberately.
    public static func isSafeToExecute(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        func notWritableByOthers(_ path: String) -> Bool {
            guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                  let permissions = attributes[.posixPermissions] as? NSNumber
            else { return false }
            // 0o022 = group-write | other-write.
            return (permissions.int16Value & 0o022) == 0
        }
        return notWritableByOthers(url.path)
            && notWritableByOthers(url.deletingLastPathComponent().path)
    }
}
