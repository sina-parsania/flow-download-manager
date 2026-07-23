// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Evaluates ordered user category rules (FR-CAT minimal).
///
/// Predicate JSON (exactly one key):
/// - `{"extension":"mp4"}` — case-insensitive path extension match
/// - `{"mimePrefix":"video/"}` — case-insensitive MIME prefix match
///
/// Action is the category `stableKey` string (e.g. `videos`).
public enum CategoryRulesEngine {
    public struct Rule: Sendable, Equatable {
        public let id: String
        public let priority: Int
        public let enabled: Bool
        public let predicateJSON: String
        public let categoryStableKey: String

        public init(
            id: String,
            priority: Int,
            enabled: Bool,
            predicateJSON: String,
            categoryStableKey: String
        ) {
            self.id = id
            self.priority = priority
            self.enabled = enabled
            self.predicateJSON = predicateJSON
            self.categoryStableKey = categoryStableKey
        }
    }

    public struct Match: Sendable, Equatable {
        public let categoryStableKey: String
        public let ruleID: String
        public let evidence: String

        public init(categoryStableKey: String, ruleID: String, evidence: String) {
            self.categoryStableKey = categoryStableKey
            self.ruleID = ruleID
            self.evidence = evidence
        }
    }

    /// First matching enabled rule in ascending priority order wins.
    public static func evaluate(
        rules: [Rule],
        filenameEvidence: String?,
        mimeEvidence: String?,
        urlPathExtension: String?
    ) -> Match? {
        let ordered = rules
            .filter(\.enabled)
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.id < rhs.id
            }
        let extCandidates = extensionCandidates(
            filenameEvidence: filenameEvidence,
            urlPathExtension: urlPathExtension
        )
        let mime = normalizedMIME(mimeEvidence)

        for rule in ordered {
            guard let predicate = parsePredicate(rule.predicateJSON) else { continue }
            switch predicate {
            case let .fileExtension(expected):
                if extCandidates.contains(expected) {
                    return Match(
                        categoryStableKey: rule.categoryStableKey,
                        ruleID: rule.id,
                        evidence: "rule:extension:\(expected)"
                    )
                }
            case let .mimePrefix(prefix):
                if let mime, mime.hasPrefix(prefix) {
                    return Match(
                        categoryStableKey: rule.categoryStableKey,
                        ruleID: rule.id,
                        evidence: "rule:mimePrefix:\(prefix)"
                    )
                }
            }
        }
        return nil
    }

    public static func extensionPredicateJSON(_ ext: String) -> String? {
        let normalized = normalizeExtension(ext)
        guard !normalized.isEmpty, normalized.utf8.count <= 64 else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["extension": normalized],
            options: [.sortedKeys]
        ),
            let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    // MARK: - Internals

    private enum Predicate {
        case fileExtension(String)
        case mimePrefix(String)
    }

    private static func parsePredicate(_ json: String) -> Predicate? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let ext = object["extension"] as? String {
            let normalized = normalizeExtension(ext)
            guard !normalized.isEmpty else { return nil }
            return .fileExtension(normalized)
        }
        if let prefix = object["mimePrefix"] as? String {
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { return nil }
            return .mimePrefix(trimmed)
        }
        return nil
    }

    private static func extensionCandidates(
        filenameEvidence: String?,
        urlPathExtension: String?
    ) -> Set<String> {
        var result: Set<String> = []
        if let filename = filenameEvidence?.trimmingCharacters(in: .whitespacesAndNewlines),
           !filename.isEmpty,
           let ext = pathExtension(of: filename) {
            result.insert(ext)
        }
        if let ext = normalizeExtensionOptional(urlPathExtension) {
            result.insert(ext)
        }
        if let path = urlPathExtension?.trimmingCharacters(in: .whitespacesAndNewlines),
           path.contains("/"),
           let ext = pathExtension(of: path) {
            result.insert(ext)
        }
        return result
    }

    private static func pathExtension(of filename: String) -> String? {
        let name = (filename as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        return normalizeExtensionOptional(ext)
    }

    private static func normalizeExtensionOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = normalizeExtension(value)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizeExtension(_ value: String) -> String {
        var ext = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ext.hasPrefix(".") {
            ext.removeFirst()
        }
        if ext.contains("/") {
            return pathExtension(of: ext) ?? ""
        }
        return ext
    }

    private static func normalizedMIME(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let withoutParams = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? raw
        return withoutParams.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
