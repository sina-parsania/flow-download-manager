// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One selectable delivery of a media page, as reported in `formats[]`.
///
/// Only progressive formats (audio and video muxed into a single file) are
/// modelled as downloadable. Adaptive DASH/HLS renditions carry audio and video
/// in separate streams and need a muxer to become one file; Flow has no muxer,
/// so those are represented but never marked ``isProgressive``.
public struct YtdlpFormat: Sendable, Equatable {
    public let formatID: String?
    public let url: String
    public let ext: String?
    public let videoCodec: String?
    public let audioCodec: String?
    public let filesizeBytes: Int64?
    public let httpHeaders: [String: String]

    public init(
        formatID: String?,
        url: String,
        ext: String?,
        videoCodec: String?,
        audioCodec: String?,
        filesizeBytes: Int64?,
        httpHeaders: [String: String]
    ) {
        self.formatID = formatID
        self.url = url
        self.ext = ext
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.filesizeBytes = filesizeBytes
        self.httpHeaders = httpHeaders
    }

    /// yt-dlp writes the string `"none"` (not JSON null) for an absent stream, so
    /// a format is progressive only when both codecs are present and not `"none"`.
    public var isProgressive: Bool {
        func present(_ codec: String?) -> Bool {
            guard let codec, !codec.isEmpty else { return false }
            return codec.lowercased() != "none"
        }
        return present(videoCodec) && present(audioCodec)
    }
}

/// Typed subset of yt-dlp `--dump-json` used for capability gating (Phase 3) and
/// for resolving a page URL to a directly downloadable file URL.
public struct YtdlpProbeResult: Sendable, Equatable {
    public let id: String?
    public let title: String?
    public let extractor: String?
    public let formatID: String?
    public let isLive: Bool
    public let drmFlag: Bool
    /// Top-level `url` yt-dlp reports for the format it selected, when present.
    public let directURL: String?
    /// Headers yt-dlp says the media host expects (User-Agent, Referer, Cookie…).
    /// Signed CDN URLs commonly 403 without them.
    public let httpHeaders: [String: String]
    public let formats: [YtdlpFormat]

    public init(
        id: String?,
        title: String?,
        extractor: String?,
        formatID: String?,
        isLive: Bool,
        drmFlag: Bool,
        directURL: String? = nil,
        httpHeaders: [String: String] = [:],
        formats: [YtdlpFormat] = []
    ) {
        self.id = id
        self.title = title
        self.extractor = extractor
        self.formatID = formatID
        self.isLive = isLive
        self.drmFlag = drmFlag
        self.directURL = directURL
        self.httpHeaders = httpHeaders
        self.formats = formats
    }

    /// The single-file rendition to hand the transfer engine, or `nil` when the
    /// page only offers adaptive streams. Prefers the largest known filesize so a
    /// resolved link is the best available quality rather than the first listed;
    /// falls back to the top-level `url` when `formats[]` is absent but yt-dlp
    /// still resolved something (common for direct-file extractors).
    public var downloadableFormat: YtdlpFormat? {
        let progressive = formats.filter(\.isProgressive)
        if let best = progressive.max(by: { ($0.filesizeBytes ?? 0) < ($1.filesizeBytes ?? 0) }) {
            return best
        }
        guard formats.isEmpty, let directURL else { return nil }
        return YtdlpFormat(
            formatID: formatID,
            url: directURL,
            ext: nil,
            videoCodec: nil,
            audioCodec: nil,
            filesizeBytes: nil,
            httpHeaders: httpHeaders
        )
    }

    public var mediaDecision: MediaPolicy.Decision {
        if drmFlag {
            return .rejectedDRM
        }
        return MediaPolicy.evaluate(urlString: id ?? "", formatID: formatID)
    }
}

public enum YtdlpJSONProbe {
    public enum ProbeError: Error, Equatable, Sendable {
        case invalidJSON
        case emptyPayload
    }

    public static func parse(stdout: Data) throws -> YtdlpProbeResult {
        guard !stdout.isEmpty else { throw ProbeError.emptyPayload }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: stdout, options: [.fragmentsAllowed])
        } catch {
            throw ProbeError.invalidJSON
        }
        guard let dict = object as? [String: Any] else { throw ProbeError.invalidJSON }
        let formatID = dict["format_id"] as? String
        let drm =
            (dict["_has_drm"] as? Bool) == true
                || (dict["drm"] as? Bool) == true
                || (formatID?.lowercased().contains("drm") ?? false)
        let topLevelHeaders = parseHeaders(dict["http_headers"])
        return YtdlpProbeResult(
            id: dict["id"] as? String,
            title: dict["title"] as? String,
            extractor: dict["extractor"] as? String,
            formatID: formatID,
            isLive: (dict["is_live"] as? Bool) ?? false,
            drmFlag: drm,
            directURL: httpURL(dict["url"]),
            httpHeaders: topLevelHeaders,
            formats: parseFormats(dict["formats"], fallbackHeaders: topLevelHeaders)
        )
    }

    /// Only `http`/`https` resolve to something the transfer engine can fetch.
    /// yt-dlp also emits `m3u8`/`rtmp`/`ws` URLs for streaming renditions, and
    /// handing one of those to curl would produce a playlist file named like a video.
    private static func httpURL(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let lowered = value.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://") else { return nil }
        return value
    }

    private static func parseHeaders(_ raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        return dict.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            }
        }
    }

    private static func parseFormats(
        _ raw: Any?,
        fallbackHeaders: [String: String]
    ) -> [YtdlpFormat] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard let url = httpURL(entry["url"]) else { return nil }
            let headers = parseHeaders(entry["http_headers"])
            return YtdlpFormat(
                formatID: entry["format_id"] as? String,
                url: url,
                ext: entry["ext"] as? String,
                videoCodec: entry["vcodec"] as? String,
                audioCodec: entry["acodec"] as? String,
                filesizeBytes: (entry["filesize"] as? NSNumber)?.int64Value
                    ?? (entry["filesize_approx"] as? NSNumber)?.int64Value,
                httpHeaders: headers.isEmpty ? fallbackHeaders : headers
            )
        }
    }
}
