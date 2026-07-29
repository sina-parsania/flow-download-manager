// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Expands a numeric range in a URL into one URL per number.
///
/// `https://host/img[001-010].jpg` becomes ten links. Sites that publish
/// sequentially numbered files are the reason every other download manager has
/// this; typing ten variants by hand is the alternative.
///
/// A pure pre-pass over the pasted text, deliberately kept out of
/// ``URLTextExtractor``: expansion happens on the raw string BEFORE the
/// candidate regex runs, so every expanded URL then goes through exactly the
/// same validation, deduplication and classification as a hand-typed one. No
/// expanded link can skip a check a pasted link is subject to.
public enum URLPatternExpander {
    /// `[start-end]` with optional zero padding taken from the first bound's
    /// width. Only digits: a letter range would collide with IPv6 literals and
    /// with ordinary bracketed text.
    private static let patternRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\[(\d+)-(\d+)\]"#,
        options: []
    )

    /// Hard ceiling on links produced from ONE pattern. A typo like `[1-999999]`
    /// must not enqueue a million jobs; the expansion is refused whole rather
    /// than silently truncated, so the user sees their own link back.
    public static let maxExpansion = 500

    public struct Expansion: Equatable {
        /// The text to hand ``URLTextExtractor``, with patterns replaced.
        public let text: String
        /// How many links the patterns produced, for the UI to report.
        public let expandedCount: Int
        /// Patterns refused for exceeding ``maxExpansion``, left verbatim in
        /// `text` so the user can see and fix them.
        public let refusedPatterns: [String]
    }

    /// Rewrites every `[start-end]` occurrence into one line per value.
    ///
    /// A line with no pattern passes through untouched, so this is safe to run
    /// over any pasted text. Only the FIRST pattern in a line is expanded:
    /// two ranges on one line is a cross product, which is a different feature
    /// and a much easier way to accidentally create thousands of jobs.
    public static func expand(_ text: String) -> Expansion {
        guard let patternRegex else {
            return Expansion(text: text, expandedCount: 0, refusedPatterns: [])
        }
        var outputLines: [String] = []
        var expandedCount = 0
        var refused: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineString = String(line)
            let ns = lineString as NSString
            guard let match = patternRegex.firstMatch(
                in: lineString,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            ) else {
                outputLines.append(lineString)
                continue
            }

            let lowerText = ns.substring(with: match.range(at: 1))
            let upperText = ns.substring(with: match.range(at: 2))
            // A bound too long to be an Int is not a range anyone meant.
            guard let lower = Int(lowerText), let upper = Int(upperText), lower <= upper else {
                outputLines.append(lineString)
                continue
            }
            let count = upper - lower + 1
            guard count <= maxExpansion else {
                refused.append(ns.substring(with: match.range))
                outputLines.append(lineString)
                continue
            }

            // Padding width comes from the first bound as written, so
            // `[001-010]` yields 001…010 and `[1-10]` yields 1…10.
            let width = lowerText.count
            let prefix = ns.substring(to: match.range.location)
            let suffix = ns.substring(from: match.range.location + match.range.length)
            for value in lower ... upper {
                let number = String(value)
                let padded = number.count >= width
                    ? number
                    : String(repeating: "0", count: width - number.count) + number
                outputLines.append(prefix + padded + suffix)
            }
            expandedCount += count
        }

        return Expansion(
            text: outputLines.joined(separator: "\n"),
            expandedCount: expandedCount,
            refusedPatterns: refused
        )
    }
}
