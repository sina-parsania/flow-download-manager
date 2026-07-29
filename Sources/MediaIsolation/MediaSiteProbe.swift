// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Detects page URLs that typically need yt-dlp, and runs an optional metadata
/// probe when a helper binary is present (ADR / Phase 3). Never downloads.
public enum MediaSiteProbe {
    public enum AvailabilityError: Error, Equatable, Sendable {
        case executableMissing
        case launchFailed
        case timedOut
        case nonZeroExit(Int32)
        case parseFailed
    }

    /// Hosts ClassificationEngine already treats as video pages. Kept here so the
    /// Compose sheet can offer a probe without coupling to classification keys.
    public static func looksLikeMediaPage(urlString: String) -> Bool {
        let lower = urlString.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        let hosts = [
            "youtube.", "youtu.be", "vimeo.", "twitch.", "dailymotion.",
            "streamable.", "nicovideo.", "bilibili.", "tiktok."
        ]
        return hosts.contains(where: { lower.contains($0) })
    }

    /// Resolves `yt-dlp`: bundled, then user-chosen, then a permission-checked
    /// well-known location. `nil` when the helper is not installed.
    public static func resolvedExecutable(
        fileManager: FileManager = .default
    ) -> URL? {
        resolvedHelper(fileManager: fileManager)?.url
    }

    /// Same resolution, but keeps where the helper came from so the UI can show
    /// the user which binary it is about to run.
    public static func resolvedHelper(
        fileManager: FileManager = .default
    ) -> MediaHelperLocator.Resolved? {
        MediaHelperLocator.resolve(name: "yt-dlp", fileManager: fileManager)
    }

    /// Metadata-only probe. Callers must treat missing binaries as a soft skip —
    /// direct file URLs still enqueue without yt-dlp.
    public static func probeMetadata(
        urlString: String,
        executableURL: URL? = nil,
        timeoutSeconds: TimeInterval = 60
    ) throws -> YtdlpProbeResult {
        guard let executable = executableURL ?? resolvedExecutable() else {
            throw AvailabilityError.executableMissing
        }
        let launcher = MediaProcessLauncher(
            executableURL: executable,
            timeoutSeconds: timeoutSeconds
        )
        let result: MediaProcessLauncher.Result
        do {
            result = try launcher.run(
                arguments: MediaProcessLauncher.ytdlpMetadataArguments(url: urlString)
            )
        } catch MediaProcessLauncher.LaunchError.executableMissing {
            throw AvailabilityError.executableMissing
        } catch MediaProcessLauncher.LaunchError.timedOut {
            throw AvailabilityError.timedOut
        } catch {
            throw AvailabilityError.launchFailed
        }
        guard result.exitCode == 0 else {
            throw AvailabilityError.nonZeroExit(result.exitCode)
        }
        do {
            return try YtdlpJSONProbe.parse(stdout: result.stdout)
        } catch {
            throw AvailabilityError.parseFailed
        }
    }
}
