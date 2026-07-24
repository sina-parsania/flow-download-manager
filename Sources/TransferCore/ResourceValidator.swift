// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the server said the resource was when a partial download started.
///
/// Persisted in the `.segmap` so a resume can ask "is this still the same file?"
/// before stitching new bytes onto old ones. Before this existed the only resume
/// check was byte count: a resource that changed but kept its length was resumed
/// into, producing a file of exactly the right size, assembled from two different
/// versions, that passed every other check in the pipeline. On a link that drops
/// often — many resumes — that was the most likely way to end up with a corrupt
/// file and no error.
public struct ResourceValidator: Codable, Sendable, Equatable {
    public let etag: String?
    public let lastModified: String?
    public let totalBytes: Int64

    public init(etag: String?, lastModified: String?, totalBytes: Int64) {
        self.etag = Self.normalized(etag)
        self.lastModified = Self.normalized(lastModified)
        self.totalBytes = totalBytes
    }

    /// The verdict of comparing a stored validator against a fresh probe.
    public enum Verdict: Sendable, Equatable {
        /// Same resource on a signal we trust. Resume.
        case matches
        /// The server contradicted the stored validator. The partial belongs to a
        /// different version and must be discarded, not resumed into.
        case changed(reason: String)
        /// Nothing to compare beyond length. Resume, because refusing here would
        /// break every server that sends neither an ETag nor a Last-Modified.
        case unverifiable
    }

    /// Compares this stored validator against what a fresh probe reports.
    ///
    /// A *missing* signal is never an error — plenty of servers send no validator
    /// at all, and a stored map written before validators existed has none either.
    /// Only a signal that is present on both sides and disagrees rejects a resume.
    public func compare(
        probeETag: String?,
        probeLastModified: String?,
        probeTotalBytes: Int64?
    ) -> Verdict {
        if let probeTotalBytes, probeTotalBytes != totalBytes {
            return .changed(reason: "length")
        }

        // Strongest signal first. A weak ETag ("W/…") only promises semantic
        // equivalence, not byte equality, so it cannot license stitching two
        // halves together — treat it as no ETag at all.
        let storedTag = Self.strongETag(etag)
        let probeTag = Self.strongETag(probeETag)
        if let storedTag, let probeTag {
            return storedTag == probeTag ? .matches : .changed(reason: "etag")
        }

        let storedModified = Self.normalized(lastModified)
        let probeModified = Self.normalized(probeLastModified)
        if let storedModified, let probeModified {
            return storedModified == probeModified
                ? .matches
                : .changed(reason: "lastModified")
        }

        return probeTotalBytes == nil ? .unverifiable : .matches
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Returns the tag only when it is a strong validator. `nil` for weak (`W/`)
    /// tags, which promise equivalence but not identical bytes.
    private static func strongETag(_ value: String?) -> String? {
        guard let tag = normalized(value) else { return nil }
        let lowered = tag.lowercased()
        if lowered.hasPrefix("w/") { return nil }
        return tag
    }
}
