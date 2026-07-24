// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A download request that has passed intent-input validation.
///
/// Shortcuts, Spotlight and the Services menu hand an intent arbitrary text that
/// never went through the Add sheet's extractor, so nothing reaches the engine
/// until it has been through `FlowIntentInput`.
public struct ValidatedDownload: Sendable, Equatable {
    /// The link exactly as it was supplied, minus surrounding whitespace. It is
    /// never rewritten — a link that needs rewriting to work is refused instead.
    public let link: String
    /// Requested save name, already checked for separators and control characters.
    public let fileName: String?
}

/// What survived validation of a list of links, and how much did not.
public struct ValidatedDownloadBatch: Sendable, Equatable {
    public let accepted: [ValidatedDownload]
    public let skippedCount: Int
}

/// Everything an intent can refuse to do, paired with the sentence a person reads.
public enum FlowIntentFailure: Error, Equatable, Sendable {
    case noLinkProvided
    case linkTooLong
    case linkNotUnderstood
    case unsupportedScheme(String)
    case tooManyLinks(limit: Int)
    case fileNameNotUsable
    case engineUnavailable
    case addFailed
    case updateFailed
}

public extension FlowIntentFailure {
    /// A plain sentence and a next step.
    ///
    /// Nothing from the transport, no status code and no underlying error value is
    /// ever interpolated here: a shortcut runs where there is no window to explain
    /// things afterwards, so the sentence has to stand on its own.
    var message: String {
        switch self {
        case .noLinkProvided:
            return "No link to download. Give Flow at least one web address, then run this again."
        case .linkTooLong:
            return "That link is too long for Flow to use. Copy the direct link to the file and try again."
        case .linkNotUnderstood:
            return "Flow could not read that link. Check it for typos or missing characters, then try again."
        case let .unsupportedScheme(scheme):
            return "Flow downloads web links only. Links that start with “\(scheme)” are not supported yet."
        case let .tooManyLinks(limit):
            return "Flow takes up to \(limit) links at a time. Split the list into smaller groups and run this again."
        case .fileNameNotUsable:
            return "That file name cannot be used. Remove any slashes or colons and try a simpler name."
        case .engineUnavailable:
            return "Flow’s background engine is not running. Open Flow once, then run this again."
        case .addFailed:
            return "Flow could not add the download just now. Open Flow and try again."
        case .updateFailed:
            return "Flow could not change the downloads just now. Open Flow and try again."
        }
    }
}

/// Validation of untrusted intent input.
///
/// `http` and `https` are the only schemes that genuinely download today, so
/// everything else is refused here with a sentence rather than accepted and then
/// failed by the transfer an hour later.
public enum FlowIntentInput {
    /// Mirrors the engine's per-link payload ceiling. A longer link is rejected at
    /// the boundary with nothing a person could act on, so it is caught here first.
    static let maxLinkBytes = 16384
    /// Mirrors the Add sheet's per-call enqueue chunk.
    static let maxLinksPerRequest = 250
    static let maxFileNameBytes = 255
    static let supportedSchemes: Set<String> = ["http", "https"]

    /// Validates a single link plus an optional save name.
    public static func validate(link: String, fileName: String? = nil) throws -> ValidatedDownload {
        let checkedLink = try normalizedLink(link)
        let checkedName = try normalizedFileName(fileName)
        return ValidatedDownload(link: checkedLink, fileName: checkedName)
    }

    /// Validates a list of links, keeping their order and dropping repeats.
    ///
    /// A batch is deliberately accepted in part: a shortcut that scrapes a page
    /// hands over whatever it found, and refusing twenty good links because the
    /// twenty-first was a mail address would make the intent useless. The number
    /// dropped is reported back so nothing disappears silently. When *nothing*
    /// survives, the first reason is what gets thrown.
    public static func validate(links: [String]) throws -> ValidatedDownloadBatch {
        guard !links.isEmpty else { throw FlowIntentFailure.noLinkProvided }
        guard links.count <= maxLinksPerRequest else {
            throw FlowIntentFailure.tooManyLinks(limit: maxLinksPerRequest)
        }

        var accepted: [ValidatedDownload] = []
        var seen: Set<String> = []
        var skipped = 0
        var firstFailure: FlowIntentFailure?
        accepted.reserveCapacity(links.count)

        for link in links {
            let checked: String
            do {
                checked = try normalizedLink(link)
            } catch let failure as FlowIntentFailure {
                if firstFailure == nil { firstFailure = failure }
                skipped += 1
                continue
            }
            guard seen.insert(checked).inserted else {
                skipped += 1
                continue
            }
            accepted.append(ValidatedDownload(link: checked, fileName: nil))
        }

        guard !accepted.isEmpty else {
            throw firstFailure ?? FlowIntentFailure.noLinkProvided
        }
        return ValidatedDownloadBatch(accepted: accepted, skippedCount: skipped)
    }

    /// Trims and checks one link, returning it unchanged when it is usable.
    public static func normalizedLink(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FlowIntentFailure.noLinkProvided }
        guard trimmed.utf8.count <= maxLinkBytes else { throw FlowIntentFailure.linkTooLong }
        guard !contains(trimmed, anyOf: rejectedLinkScalars) else {
            throw FlowIntentFailure.linkNotUnderstood
        }
        guard let components = URLComponents(string: trimmed) else {
            throw FlowIntentFailure.linkNotUnderstood
        }
        guard let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            throw FlowIntentFailure.linkNotUnderstood
        }
        guard supportedSchemes.contains(scheme) else {
            throw FlowIntentFailure.unsupportedScheme(schemeLabel(scheme))
        }
        guard let host = components.host, !host.isEmpty else {
            throw FlowIntentFailure.linkNotUnderstood
        }
        return trimmed
    }

    /// Trims and checks a requested save name. Blank means "no preference".
    public static func normalizedFileName(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= maxFileNameBytes else { throw FlowIntentFailure.fileNameNotUsable }
        guard trimmed != ".", trimmed != ".." else { throw FlowIntentFailure.fileNameNotUsable }
        guard !contains(trimmed, anyOf: rejectedFileNameScalars) else {
            throw FlowIntentFailure.fileNameNotUsable
        }
        return trimmed
    }

    // MARK: - Private

    private static let rejectedLinkScalars = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)

    private static let rejectedFileNameScalars = CharacterSet.controlCharacters
        .union(CharacterSet(charactersIn: "/:"))

    private static func contains(_ value: String, anyOf set: CharacterSet) -> Bool {
        value.unicodeScalars.contains { set.contains($0) }
    }

    /// Keeps an unrecognised scheme printable before it is echoed back.
    ///
    /// The scheme comes from intent input, so only a short run of scheme-legal
    /// characters ever reaches the sentence a person reads.
    private static func schemeLabel(_ scheme: String) -> String {
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "+-."))
        let kept = scheme.unicodeScalars
            .filter { allowed.contains($0) }
            .map(Character.init)
        return String(String(kept).prefix(12))
    }
}
