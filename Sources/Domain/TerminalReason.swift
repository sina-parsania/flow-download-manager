// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed, stable terminal reason codes (`04-domain-and-data-contracts.md` §5).
///
/// Raw libcurl/OSStatus/errno/yt-dlp/FFmpeg/libtorrent details are nested
/// diagnostics, never this public contract. Localized presentation is derived
/// separately from these codes.
public enum TerminalReason: String, CaseIterable, Sendable, Codable {
    case userCancelled
    case unsupportedScheme
    case unsupportedProtectedContent
    case authenticationRequired
    case authenticationRejected
    case proxyAuthenticationRequired
    case permissionDenied
    case destinationUnavailable
    case diskFull
    case resourceChanged
    case rangeProtocolViolation
    case checksumMismatch
    case tlsFailure
    case networkUnavailable
    case serverRateLimited
    case serverUnavailable
    case notFound
    case dependencyUnavailable
    case dependencyProtocolMismatch
    case postProcessingFailed
    case unsafePath
    case databaseRecoveryRequired

    /// The terminal job state this reason implies. `userCancelled` maps to
    /// `cancelled`; every other reason maps to `failed`. `completed` carries no
    /// terminal reason.
    public var impliedState: JobState {
        self == .userCancelled ? .cancelled : .failed
    }
}
