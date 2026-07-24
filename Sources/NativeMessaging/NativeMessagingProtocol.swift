// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Versioned Native Messaging envelope.
///
/// Version 1 (`SchemaVersions.nativeMessaging`) carries URLs only. Version 2 adds
/// the `headers` array so the request context the browser would have sent
/// (Referer / User-Agent / Cookie) survives the hand-off to the engine. The host
/// keeps accepting version 1 so an extension that has not updated still works —
/// it just cannot authenticate downloads.
public enum NativeMessagingProtocol {
    /// Envelope version this host speaks and answers with.
    public static let currentVersion = 2

    /// Oldest envelope still accepted. Equal to ``SchemaVersions/nativeMessaging``,
    /// the version the first shipped extension speaks.
    public static let minimumSupportedVersion = SchemaVersions.nativeMessaging

    /// First version whose requests may carry a `headers` array.
    public static let headersIntroducedInVersion = 2

    public enum Command: String, Codable, Sendable {
        case ping
        case enqueueURLs
        case listJobs
    }

    /// How an enqueue request was actually satisfied, so the extension can tell the
    /// user whether the download is running or still needs a click.
    public enum Route: String, Codable, Sendable {
        /// Accepted by the engine over authenticated XPC.
        case engine
        /// Handed to the app's Add sheet because the engine was not reachable.
        case appHandoff
    }

    /// One request header supplied by the extension. Untrusted input: names and
    /// values are filtered by ``NativeMessagingHeaderPolicy`` before they reach XPC,
    /// and values are never logged.
    public struct Header: Codable, Sendable, Equatable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public struct Request: Codable, Sendable, Equatable {
        public var protocolVersion: Int
        public var requestID: String
        public var command: Command
        public var urls: [String]?
        public var displayName: String?
        /// Browser request context, version 2 and later. Ignored on version 1 envelopes.
        public var headers: [Header]?

        public init(
            protocolVersion: Int = NativeMessagingProtocol.currentVersion,
            requestID: String,
            command: Command,
            urls: [String]? = nil,
            displayName: String? = nil,
            headers: [Header]? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.requestID = requestID
            self.command = command
            self.urls = urls
            self.displayName = displayName
            self.headers = headers
        }
    }

    public struct Response: Codable, Sendable, Equatable {
        public var protocolVersion: Int
        public var requestID: String
        public var ok: Bool
        public var errorCode: String?
        public var message: String?
        public var acceptedCount: Int?
        public var jobIDs: [String]?
        public var jobCount: Int?
        /// Set on a successful enqueue. Absent on version 1 answers is fine — the
        /// older extension ignores unknown keys.
        public var route: Route?
        /// Canonical names of headers the host would not forward. Names only; a
        /// header value is never echoed back and never logged.
        public var droppedHeaderNames: [String]?
        /// Stable machine-readable hint the extension maps to its own copy.
        public var warningCode: String?

        public init(
            protocolVersion: Int = NativeMessagingProtocol.currentVersion,
            requestID: String,
            ok: Bool,
            errorCode: String? = nil,
            message: String? = nil,
            acceptedCount: Int? = nil,
            jobIDs: [String]? = nil,
            jobCount: Int? = nil,
            route: Route? = nil,
            droppedHeaderNames: [String]? = nil,
            warningCode: String? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.requestID = requestID
            self.ok = ok
            self.errorCode = errorCode
            self.message = message
            self.acceptedCount = acceptedCount
            self.jobIDs = jobIDs
            self.jobCount = jobCount
            self.route = route
            self.droppedHeaderNames = droppedHeaderNames
            self.warningCode = warningCode
        }

        public static func failure(
            protocolVersion: Int = NativeMessagingProtocol.currentVersion,
            requestID: String,
            errorCode: String,
            message: String
        ) -> Response {
            Response(
                protocolVersion: protocolVersion,
                requestID: requestID,
                ok: false,
                errorCode: errorCode,
                message: message
            )
        }
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case invalidJSON
        case unsupportedProtocolVersion(Int)
    }

    /// Decodes and version-gates a request body.
    ///
    /// Envelopes older than ``headersIntroducedInVersion`` have their `headers`
    /// stripped: a version 1 client has no header channel, so anything claiming
    /// otherwise is discarded rather than trusted.
    public static func decodeRequest(from body: Data) throws -> Request {
        let decoder = JSONDecoder()
        var request: Request
        do {
            request = try decoder.decode(Request.self, from: body)
        } catch {
            throw DecodeError.invalidJSON
        }
        guard request.protocolVersion >= minimumSupportedVersion,
              request.protocolVersion <= currentVersion
        else {
            throw DecodeError.unsupportedProtocolVersion(request.protocolVersion)
        }
        if request.protocolVersion < headersIntroducedInVersion {
            request.headers = nil
        }
        return request
    }

    public static func encodeResponse(_ response: Response) throws -> Data {
        try JSONEncoder().encode(response)
    }
}
