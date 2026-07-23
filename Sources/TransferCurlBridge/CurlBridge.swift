// SPDX-License-Identifier: GPL-3.0-or-later

import CCurl
import Foundation

/// Runtime capabilities of the pinned libcurl build (FR-TRN-001…005).
/// Values come from `curl_version_info`, not from marketing assumptions or
/// Homebrew/system curl.
public struct CurlCapabilities: Sendable, Equatable {
    public let version: String
    public let versionNumber: UInt32
    public let sslVersion: String?
    public let libsshVersion: String?
    public let nghttp2Version: String?
    public let protocols: Set<String>
    public let features: CurlFeatureSet

    public var supportsHTTP: Bool {
        protocols.contains("http")
    }

    public var supportsHTTPS: Bool {
        protocols.contains("https")
    }

    public var supportsFTP: Bool {
        protocols.contains("ftp")
    }

    public var supportsFTPS: Bool {
        protocols.contains("ftps")
    }

    public var supportsSFTP: Bool {
        protocols.contains("sftp")
    }

    public var supportsHTTP2: Bool {
        features.contains(.http2)
    }

    public var supportsAsynchDNS: Bool {
        features.contains(.asynchDNS)
    }

    public var supportsMultiSSL: Bool {
        features.contains(.multiSSL)
    }
}

public struct CurlFeatureSet: OptionSet, Sendable, Equatable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let ipv6 = CurlFeatureSet(rawValue: 1 << 0)
    public static let ssl = CurlFeatureSet(rawValue: 1 << 1)
    public static let libz = CurlFeatureSet(rawValue: 1 << 2)
    public static let asynchDNS = CurlFeatureSet(rawValue: 1 << 3)
    public static let largeFile = CurlFeatureSet(rawValue: 1 << 4)
    public static let idn = CurlFeatureSet(rawValue: 1 << 5)
    public static let sspi = CurlFeatureSet(rawValue: 1 << 6)
    public static let ntlm = CurlFeatureSet(rawValue: 1 << 7)
    public static let debug = CurlFeatureSet(rawValue: 1 << 8)
    public static let spnego = CurlFeatureSet(rawValue: 1 << 9)
    public static let http2 = CurlFeatureSet(rawValue: 1 << 11)
    public static let unixSockets = CurlFeatureSet(rawValue: 1 << 12)
    public static let multiSSL = CurlFeatureSet(rawValue: 1 << 13)
    public static let altSvc = CurlFeatureSet(rawValue: 1 << 14)
    public static let http3 = CurlFeatureSet(rawValue: 1 << 15)
    public static let httpsProxy = CurlFeatureSet(rawValue: 1 << 16)
}

public enum CurlBridge {
    /// Process-wide libcurl initialization. Safe to call repeatedly.
    public static func initialize() throws {
        let code = DMCurlGlobalInit()
        guard code == CURLE_OK else {
            throw CurlBridgeError.globalInitFailed(code)
        }
    }

    public static func cleanup() {
        DMCurlGlobalCleanup()
    }

    public static func capabilities() -> CurlCapabilities {
        let info = DMCurlVersionInfo().pointee
        let version = String(cString: info.version)
        let ssl: String? = info.ssl_version.map { String(cString: $0) }
        let libssh: String? = info.libssh_version.map { String(cString: $0) }
        let nghttp2: String? = info.nghttp2_version.map { String(cString: $0) }

        var protocols = Set<String>()
        if let protocolsPtr = info.protocols {
            var index = 0
            while true {
                guard let entry = protocolsPtr.advanced(by: index).pointee else { break }
                protocols.insert(String(cString: entry).lowercased())
                index += 1
            }
        }

        var featureNames = Set<String>()
        if let namesPtr = info.feature_names {
            var index = 0
            while true {
                guard let entry = namesPtr.advanced(by: index).pointee else { break }
                featureNames.insert(String(cString: entry).lowercased())
                index += 1
            }
        }

        var features = CurlFeatureSet()
        if featureNames.contains("ipv6") { features.insert(.ipv6) }
        if featureNames.contains("ssl") { features.insert(.ssl) }
        if featureNames.contains("libz") { features.insert(.libz) }
        if featureNames.contains("asynchdns") { features.insert(.asynchDNS) }
        if featureNames.contains("largefile") { features.insert(.largeFile) }
        if featureNames.contains("idn") { features.insert(.idn) }
        if featureNames.contains("sspi") { features.insert(.sspi) }
        if featureNames.contains("ntlm") { features.insert(.ntlm) }
        if featureNames.contains("debug") { features.insert(.debug) }
        if featureNames.contains("spnego") { features.insert(.spnego) }
        if featureNames.contains("http2") { features.insert(.http2) }
        if featureNames.contains("unixsockets") { features.insert(.unixSockets) }
        if featureNames.contains("multissl") { features.insert(.multiSSL) }
        if featureNames.contains("alt-svc") || featureNames.contains("altsvc") {
            features.insert(.altSvc)
        }
        if featureNames.contains("http3") { features.insert(.http3) }
        if featureNames.contains("https-proxy") || featureNames.contains("httpsproxy") {
            features.insert(.httpsProxy)
        }

        return CurlCapabilities(
            version: version,
            versionNumber: info.version_num,
            sslVersion: ssl,
            libsshVersion: libssh,
            nghttp2Version: nghttp2,
            protocols: protocols,
            features: features
        )
    }
}

public enum CurlBridgeError: Error, Equatable, Sendable {
    case globalInitFailed(CURLcode)
    case urlParseFailed(CURLUcode)
    case unsupportedScheme(String)
    case emptyURL
}

/// Parsed URL using libcurl's URL API (scheme allowlist for Phase 1).
public struct CurlURL: Sendable, Equatable {
    public let raw: String
    public let scheme: String
    public let host: String?
    public let port: UInt16?
    public let path: String?
    /// Query string without leading `?`. Never logged by this type.
    public let query: String?

    public var queryPresent: Bool {
        query != nil
    }

    public var isPhase1Supported: Bool {
        switch scheme {
        case "http", "https", "ftp", "ftps", "sftp":
            return true
        default:
            return false
        }
    }

    /// Deterministic dedupe key: lowercased scheme/host, omits default ports, keeps path/query.
    public var normalizationKey: String {
        var parts: [String] = [scheme]
        if let host = host?.lowercased() {
            parts.append("://")
            parts.append(host)
        }
        if let port {
            let isDefault =
                (scheme == "http" && port == 80)
                    || (scheme == "https" && port == 443)
                    || (scheme == "ftp" && port == 21)
                    || (scheme == "ftps" && port == 990)
                    || (scheme == "sftp" && port == 22)
            if !isDefault {
                parts.append(":")
                parts.append(String(port))
            }
        }
        parts.append(path ?? "/")
        if let query {
            parts.append("?")
            parts.append(query)
        }
        return parts.joined()
    }
}

public enum CurlURLParser {
    private static let maxURLBytes = 16384

    public static func parse(_ string: String) throws -> CurlURL {
        guard !string.isEmpty else { throw CurlBridgeError.emptyURL }
        guard string.utf8.count <= maxURLBytes else {
            throw CurlBridgeError.urlParseFailed(CURLUE_MALFORMED_INPUT)
        }

        guard let handle = curl_url() else {
            throw CurlBridgeError.urlParseFailed(CURLUE_OUT_OF_MEMORY)
        }
        defer { curl_url_cleanup(handle) }

        let setCode = string.withCString { cString in
            DMCurlURLSetURL(handle, cString)
        }
        guard setCode == CURLUE_OK else {
            throw CurlBridgeError.urlParseFailed(setCode)
        }

        let scheme = try part(handle, CURLUPART_SCHEME)?.lowercased() ?? ""
        let host = try part(handle, CURLUPART_HOST)
        let path = try part(handle, CURLUPART_PATH)
        let query = try part(handle, CURLUPART_QUERY)
        let portString = try part(handle, CURLUPART_PORT)
        let port = portString.flatMap(UInt16.init)

        return CurlURL(
            raw: string,
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            query: query
        )
    }

    private static func part(_ handle: OpaquePointer, _ part: CURLUPart) throws -> String? {
        var value: UnsafeMutablePointer<CChar>?
        let code = DMCurlURLGetString(handle, part, &value, 0)
        defer {
            if let value {
                curl_free(value)
            }
        }
        switch code {
        case CURLUE_OK:
            guard let value else { return nil }
            return String(cString: value)
        case CURLUE_NO_SCHEME, CURLUE_NO_HOST, CURLUE_NO_PORT, CURLUE_NO_QUERY,
             CURLUE_NO_FRAGMENT, CURLUE_NO_USER, CURLUE_NO_PASSWORD, CURLUE_NO_OPTIONS,
             CURLUE_NO_ZONEID:
            return nil
        default:
            throw CurlBridgeError.urlParseFailed(code)
        }
    }
}
