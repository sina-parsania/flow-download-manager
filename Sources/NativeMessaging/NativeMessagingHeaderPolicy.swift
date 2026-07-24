// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import XPCContracts

/// Filters the header set an extension attaches to an enqueue request down to
/// something the engine will accept.
///
/// Everything arriving from the browser is untrusted, so the policy is an
/// allowlist rather than a denylist: only the names below can ever reach a
/// transfer, each pair must still pass ``HeaderValidator`` (which rejects
/// hop-by-hop names and CR/LF injection), and the encoded set is bounded by the
/// same limit ``EnqueueBatchRequest`` enforces when it decodes.
public enum NativeMessagingHeaderPolicy {
    /// Forwardable header names in descending order of usefulness for an
    /// authenticated download. The order is also the eviction order when the
    /// encoded set has to be trimmed: the last entry goes first.
    public static let allowedNames = ["Cookie", "Referer", "User-Agent", "Accept", "Accept-Language"]

    /// `EnqueueBatchRequest.init?(coder:)` rejects a longer `customHeadersJSON`
    /// (measured in UTF-16 units, as `NSString.length` is), which would surface as
    /// an opaque decode failure. Trim here instead.
    public static let maxEncodedLength = EngineXPC.maxPayloadStringLength

    struct Pair {
        let name: String
        let value: String
    }

    public struct Result: Sendable, Equatable {
        /// Ready for `EnqueueBatchRequest.customHeadersJSON`, or `nil` when nothing survived.
        public var customHeadersJSON: String?
        /// Canonical names actually forwarded, in ``allowedNames`` order.
        public var forwardedNames: [String]
        /// Canonical names recognised but not forwarded. Safe to show a user.
        public var droppedNames: [String]

        public init(
            customHeadersJSON: String? = nil,
            forwardedNames: [String] = [],
            droppedNames: [String] = []
        ) {
            self.customHeadersJSON = customHeadersJSON
            self.forwardedNames = forwardedNames
            self.droppedNames = droppedNames
        }
    }

    /// Sanitizes `headers` for a batch of `urlCount` URLs.
    ///
    /// A `Cookie` is only forwarded for a single-URL batch. The engine applies
    /// `customHeadersJSON` to every job in the batch, so a multi-URL batch would
    /// otherwise replay one site's session cookie against every other host in the
    /// list. Names outside ``allowedNames`` are dropped without being echoed back.
    /// A repeated name keeps its first occurrence.
    public static func sanitize(
        _ headers: [NativeMessagingProtocol.Header]?,
        urlCount: Int
    ) -> Result {
        guard let headers, !headers.isEmpty else { return Result() }

        var accepted: [String: String] = [:]
        var dropped: [String] = []

        func drop(_ canonical: String) {
            guard !dropped.contains(canonical) else { return }
            dropped.append(canonical)
        }

        for header in headers {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let canonical = canonicalName(for: name) else { continue }
            guard accepted[canonical] == nil else { continue }
            guard !header.value.isEmpty,
                  HeaderValidator.validate(name: canonical, value: header.value)
            else {
                drop(canonical)
                continue
            }
            if canonical == "Cookie", urlCount != 1 {
                drop(canonical)
                continue
            }
            accepted[canonical] = header.value
        }

        var ordered: [Pair] = []
        for name in allowedNames {
            guard let value = accepted[name] else { continue }
            ordered.append(Pair(name: name, value: value))
        }

        while !ordered.isEmpty {
            guard let encoded = encode(ordered) else {
                // Every pair already passed validation, so this only fires if
                // encoding itself fails; forward nothing rather than a partial set.
                for pair in ordered {
                    drop(pair.name)
                }
                break
            }
            if encoded.utf16.count <= maxEncodedLength {
                return Result(
                    customHeadersJSON: encoded,
                    forwardedNames: ordered.map(\.name),
                    droppedNames: dropped
                )
            }
            drop(ordered.removeLast().name)
        }

        return Result(forwardedNames: [], droppedNames: dropped)
    }

    /// Maps a case-insensitive header name onto its canonical allowlisted spelling.
    public static func canonicalName(for name: String) -> String? {
        let lowered = name.lowercased()
        return allowedNames.first { $0.lowercased() == lowered }
    }

    private static func encode(_ pairs: [Pair]) -> String? {
        try? HeaderValidator.encodeExtraHeadersJSON(pairs.map { (name: $0.name, value: $0.value) })
    }
}
