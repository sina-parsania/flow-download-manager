// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TransferCurlBridge

/// Streaming, order-preserving URL extraction from arbitrary text (FR-ING-001…005).
public enum URLTextExtractor {
    public struct ExtractionLimits: Sendable, Equatable {
        public var maxInputBytes: Int
        public var maxURLCount: Int

        public init(maxInputBytes: Int = 8_000_000, maxURLCount: Int = 50000) {
            self.maxInputBytes = maxInputBytes
            self.maxURLCount = maxURLCount
        }
    }

    public struct Item: Sendable, Equatable {
        public let index: Int
        public let raw: String
        public let normalized: String?
        public let scheme: String?
        public let host: String?
        public let status: Status
        public let duplicateOfIndex: Int?

        public enum Status: String, Sendable, Equatable {
            case valid
            case duplicate
            case unsupported
            case invalid
        }
    }

    public struct Result: Sendable, Equatable {
        public let items: [Item]
        public let validCount: Int
        public let duplicateCount: Int
        public let unsupportedCount: Int
        public let invalidCount: Int
    }

    private static let candidateRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?i)\b((?:https?|ftps?|sftp|magnet):[^\s<>"'\]]+)"#,
        options: []
    )

    public static func extract(
        from text: String,
        limits: ExtractionLimits = ExtractionLimits()
    ) -> Result {
        precondition(limits.maxInputBytes > 0)
        precondition(limits.maxURLCount > 0)

        guard let candidateRegex else {
            return Result(items: [], validCount: 0, duplicateCount: 0, unsupportedCount: 0, invalidCount: 0)
        }

        let truncated = truncateUTF8(text, maxBytes: limits.maxInputBytes)
        let ns = truncated as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = candidateRegex.matches(in: truncated, options: [], range: full)

        var items: [Item] = []
        items.reserveCapacity(min(matches.count, limits.maxURLCount))
        var firstIndexByKey: [String: Int] = [:]
        var valid = 0
        var duplicate = 0
        var unsupported = 0
        var invalid = 0

        for match in matches {
            if items.count >= limits.maxURLCount { break }
            let rawRange = match.range(at: 1)
            guard rawRange.location != NSNotFound else { continue }
            var raw = ns.substring(with: rawRange)
            raw = trimTrailingPunctuation(raw)

            let index = items.count
            if raw.lowercased().hasPrefix("magnet:") {
                items.append(
                    Item(
                        index: index,
                        raw: raw,
                        normalized: nil,
                        scheme: "magnet",
                        host: nil,
                        status: .unsupported,
                        duplicateOfIndex: nil
                    )
                )
                unsupported += 1
                continue
            }

            do {
                let parsed = try CurlURLParser.parse(raw)
                guard parsed.isPhase1Supported else {
                    items.append(
                        Item(
                            index: index,
                            raw: raw,
                            normalized: nil,
                            scheme: parsed.scheme,
                            host: parsed.host,
                            status: .unsupported,
                            duplicateOfIndex: nil
                        )
                    )
                    unsupported += 1
                    continue
                }

                let key = parsed.normalizationKey
                if let prior = firstIndexByKey[key] {
                    items.append(
                        Item(
                            index: index,
                            raw: raw,
                            normalized: key,
                            scheme: parsed.scheme,
                            host: parsed.host,
                            status: .duplicate,
                            duplicateOfIndex: prior
                        )
                    )
                    duplicate += 1
                } else {
                    firstIndexByKey[key] = index
                    items.append(
                        Item(
                            index: index,
                            raw: raw,
                            normalized: key,
                            scheme: parsed.scheme,
                            host: parsed.host,
                            status: .valid,
                            duplicateOfIndex: nil
                        )
                    )
                    valid += 1
                }
            } catch {
                items.append(
                    Item(
                        index: index,
                        raw: raw,
                        normalized: nil,
                        scheme: nil,
                        host: nil,
                        status: .invalid,
                        duplicateOfIndex: nil
                    )
                )
                invalid += 1
            }
        }

        return Result(
            items: items,
            validCount: valid,
            duplicateCount: duplicate,
            unsupportedCount: unsupported,
            invalidCount: invalid
        )
    }

    private static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var end = text.startIndex
        var count = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let byteCount = text[end ..< next].utf8.count
            if count + byteCount > maxBytes { break }
            count += byteCount
            end = next
        }
        return String(text[..<end])
    }

    private static func trimTrailingPunctuation(_ value: String) -> String {
        var end = value.endIndex
        let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\"", ">"]
        while end > value.startIndex {
            let prev = value.index(before: end)
            if trailing.contains(value[prev]) {
                end = prev
            } else {
                break
            }
        }
        return String(value[..<end])
    }
}
