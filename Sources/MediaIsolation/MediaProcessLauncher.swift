// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Rejects DRM / protected-media extraction requests (Phase 3 hard constraint).
public enum MediaPolicy {
    public enum Decision: Sendable, Equatable {
        case allowed
        case rejectedDRM
    }

    public static func evaluate(urlString: String, formatID: String?) -> Decision {
        let lowered = urlString.lowercased()
        if lowered.contains("drm") || (formatID?.lowercased().contains("drm") ?? false) {
            return .rejectedDRM
        }
        return .allowed
    }
}

/// Launches pinned media helper binaries with argv arrays only (no shell).
public struct MediaProcessLauncher: Sendable {
    public struct Result: Sendable, Equatable {
        public let exitCode: Int32
        public let stdout: Data
        public let stderr: Data
    }

    public enum LaunchError: Error, Equatable, Sendable {
        case executableMissing
        case timedOut
        case spawnFailed
    }

    public var executableURL: URL
    public var timeoutSeconds: TimeInterval

    public init(executableURL: URL, timeoutSeconds: TimeInterval = 120) {
        self.executableURL = executableURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(arguments: [String], environment: [String: String] = [:]) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LaunchError.executableMissing
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw LaunchError.spawnFailed
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw LaunchError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return Result(
            exitCode: process.terminationStatus,
            stdout: out.fileHandleForReading.readDataToEndOfFile(),
            stderr: err.fileHandleForReading.readDataToEndOfFile()
        )
    }

    /// Builds yt-dlp argv for a metadata-only probe (no download).
    public static func ytdlpMetadataArguments(url: String) -> [String] {
        ["--dump-json", "--no-playlist", "--no-warnings", "--", url]
    }
}
