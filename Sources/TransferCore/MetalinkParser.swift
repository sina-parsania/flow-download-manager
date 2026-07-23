// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Metalink 3/4 metadata reader for multi-source HTTP(S) (FR-MSRC).
/// Does not download; callers prove identity before combining ranges.
public enum MetalinkParser {
    public enum ParseError: Error, Equatable, Sendable {
        case invalidXML
        case missingFiles
        case emptyMirrors
    }

    public struct Mirror: Sendable, Equatable {
        public let url: String
        public let preference: Int?

        public init(url: String, preference: Int? = nil) {
            self.url = url
            self.preference = preference
        }
    }

    public struct Checksum: Sendable, Equatable {
        public let algorithm: String
        public let value: String

        public init(algorithm: String, value: String) {
            self.algorithm = algorithm.lowercased()
            self.value = value.lowercased()
        }
    }

    public struct FileEntry: Sendable, Equatable {
        public let name: String
        public let size: Int64?
        public let mirrors: [Mirror]
        public let checksums: [Checksum]

        public init(name: String, size: Int64?, mirrors: [Mirror], checksums: [Checksum]) {
            self.name = name
            self.size = size
            self.mirrors = mirrors
            self.checksums = checksums
        }

        /// True when size + at least one strong checksum are present (FR-MSRC-002 gate).
        public var hasProvenIdentity: Bool {
            guard size != nil else { return false }
            let strong = Set(["sha-256", "sha256", "sha-512", "sha512"])
            return checksums.contains { strong.contains($0.algorithm) }
        }
    }

    public struct Document: Sendable, Equatable {
        public let files: [FileEntry]

        public init(files: [FileEntry]) {
            self.files = files
        }
    }

    public static func parse(xml data: Data) throws -> Document {
        let delegate = MetalinkSAX()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.invalidXML }
        guard !delegate.files.isEmpty else { throw ParseError.missingFiles }
        for file in delegate.files where file.mirrors.isEmpty {
            throw ParseError.emptyMirrors
        }
        return Document(files: delegate.files)
    }
}

private final class MetalinkSAX: NSObject, XMLParserDelegate {
    var files: [MetalinkParser.FileEntry] = []

    private var currentName = ""
    private var currentSize: Int64?
    private var currentMirrors: [MetalinkParser.Mirror] = []
    private var currentChecksums: [MetalinkParser.Checksum] = []
    private var textBuffer = ""
    private var inFile = false
    private var checksumAlgorithm: String?
    private var urlPreference: Int?

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        textBuffer = ""
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch local {
        case "file":
            inFile = true
            currentName = attributeDict["name"] ?? ""
            currentSize = nil
            currentMirrors = []
            currentChecksums = []
        case "url":
            if let pref = attributeDict["preference"], let value = Int(pref) {
                urlPreference = value
            } else {
                urlPreference = nil
            }
        case "hash":
            checksumAlgorithm = attributeDict["type"] ?? attributeDict["algo"]
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { textBuffer = "" }

        guard inFile else { return }
        switch local {
        case "size":
            currentSize = Int64(text)
        case "url":
            if !text.isEmpty {
                currentMirrors.append(MetalinkParser.Mirror(url: text, preference: urlPreference))
            }
            urlPreference = nil
        case "hash":
            if let algorithm = checksumAlgorithm, !text.isEmpty {
                currentChecksums.append(MetalinkParser.Checksum(algorithm: algorithm, value: text))
            }
            checksumAlgorithm = nil
        case "file":
            let name = currentName.isEmpty ? "download" : currentName
            let sorted = currentMirrors.sorted { lhs, rhs in
                (lhs.preference ?? Int.max) < (rhs.preference ?? Int.max)
            }
            files.append(
                MetalinkParser.FileEntry(
                    name: name,
                    size: currentSize,
                    mirrors: sorted,
                    checksums: currentChecksums
                )
            )
            inFile = false
        default:
            break
        }
    }
}
