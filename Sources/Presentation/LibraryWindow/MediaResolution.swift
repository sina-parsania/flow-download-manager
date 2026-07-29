// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import MediaIsolation

/// Turns a yt-dlp probe of a media page into either a queueable direct link or a
/// plain reason it cannot be queued.
///
/// Pure and view-free so the rules are unit-testable: the sheet only renders what
/// this returns. `MediaIsolation` stays a probe — nothing here transfers bytes; a
/// resolved link goes through the same `enqueueBatch` path as a pasted URL.
enum MediaResolution {
    /// Headers yt-dlp reports that must never reach a segmented transfer.
    ///
    /// `Accept-Encoding` is the dangerous one: a server that honours it answers a
    /// `Range` request with compressed bytes, so the offsets the segment ledger
    /// wrote no longer describe the file and the merged result is corrupt. The
    /// hop-by-hop names are already rejected by ``HeaderValidator``.
    private static let droppedHeaderNames: Set<String> = ["accept-encoding"]

    struct Resolved: Equatable {
        let sourceURL: String
        let title: String?
        let downloadURL: String
        /// Pre-encoded for `enqueueBatch(customHeadersJSON:)`; `nil` when the page
        /// needs no special headers.
        let headersJSON: String?
        /// True when the resolved link is bound to a session cookie. Those skip the
        /// range probe, so they arrive on one connection instead of several.
        let isSingleConnection: Bool
    }

    enum Outcome: Equatable, Identifiable {
        case resolved(Resolved)
        case blocked(sourceURL: String, title: String?, reason: String)

        var id: String {
            switch self {
            case let .resolved(resolved): resolved.sourceURL
            case let .blocked(sourceURL, _, _): sourceURL
            }
        }

        var sourceURL: String {
            switch self {
            case let .resolved(resolved): resolved.sourceURL
            case let .blocked(sourceURL, _, _): sourceURL
            }
        }

        var title: String? {
            switch self {
            case let .resolved(resolved): resolved.title
            case let .blocked(_, title, _): title
            }
        }
    }

    /// Applies the media policy gate, then resolves a single downloadable file.
    /// Order matters: DRM and live checks run before anything is offered to queue.
    static func resolve(sourceURL: String, probe: YtdlpProbeResult) -> Outcome {
        let title = probe.title
        if probe.mediaDecision == .rejectedDRM {
            return .blocked(
                sourceURL: sourceURL,
                title: title,
                reason: "Copy-protected — Flow will not download this."
            )
        }
        if probe.isLive {
            return .blocked(
                sourceURL: sourceURL,
                title: title,
                reason: "Live stream — there is no finished file to download yet."
            )
        }
        guard let format = probe.downloadableFormat else {
            // Two different refusals, because the distinction is the difference
            // between "wait for a future version" and "this will never work here".
            let streamOnly = probe.formats.contains(where: \.isSegmentedDelivery)
                || (probe.formats.isEmpty && probe.deliveryProtocol != nil)
            return .blocked(
                sourceURL: sourceURL,
                title: title,
                reason: streamOnly
                    ? "This page streams in pieces rather than offering a single "
                    + "file, which Flow can't download yet."
                    : "This page only offers separate audio and video, "
                    + "which Flow cannot join into one file."
            )
        }
        let headers = usableHeaders(format.httpHeaders)
        return .resolved(
            Resolved(
                sourceURL: sourceURL,
                title: title,
                downloadURL: format.url,
                headersJSON: encode(headers),
                isSingleConnection: headers.contains { $0.name.lowercased() == "cookie" }
            )
        )
    }

    /// Keeps only headers the engine will accept, dropping the rest rather than
    /// failing the whole download over one unusable name.
    private static func usableHeaders(
        _ headers: [String: String]
    ) -> [(name: String, value: String)] {
        headers
            .filter { !droppedHeaderNames.contains($0.key.lowercased()) }
            .filter { HeaderValidator.validate(name: $0.key, value: $0.value) }
            .map { (name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private static func encode(_ headers: [(name: String, value: String)]) -> String? {
        guard !headers.isEmpty else { return nil }
        return try? HeaderValidator.encodeExtraHeadersJSON(headers)
    }
}
