// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Typed subset of yt-dlp `--dump-json` used for capability gating (Phase 3).
public struct YtdlpProbeResult: Sendable, Equatable {
    public let id: String?
    public let title: String?
    public let extractor: String?
    public let formatID: String?
    public let isLive: Bool
    public let drmFlag: Bool

    public init(
        id: String?,
        title: String?,
        extractor: String?,
        formatID: String?,
        isLive: Bool,
        drmFlag: Bool
    ) {
        self.id = id
        self.title = title
        self.extractor = extractor
        self.formatID = formatID
        self.isLive = isLive
        self.drmFlag = drmFlag
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
        return YtdlpProbeResult(
            id: dict["id"] as? String,
            title: dict["title"] as? String,
            extractor: dict["extractor"] as? String,
            formatID: formatID,
            isLive: (dict["is_live"] as? Bool) ?? false,
            drmFlag: drm
        )
    }
}
