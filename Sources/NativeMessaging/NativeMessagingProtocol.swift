// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Versioned Native Messaging envelope (`SchemaVersions.nativeMessaging`).
public enum NativeMessagingProtocol {
    public enum Command: String, Codable, Sendable {
        case ping
        case enqueueURLs
        case listJobs
    }

    public struct Request: Codable, Sendable, Equatable {
        public var protocolVersion: Int
        public var requestID: String
        public var command: Command
        public var urls: [String]?
        public var displayName: String?

        public init(
            protocolVersion: Int = SchemaVersions.nativeMessaging,
            requestID: String,
            command: Command,
            urls: [String]? = nil,
            displayName: String? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.requestID = requestID
            self.command = command
            self.urls = urls
            self.displayName = displayName
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

        public init(
            protocolVersion: Int = SchemaVersions.nativeMessaging,
            requestID: String,
            ok: Bool,
            errorCode: String? = nil,
            message: String? = nil,
            acceptedCount: Int? = nil,
            jobIDs: [String]? = nil,
            jobCount: Int? = nil
        ) {
            self.protocolVersion = protocolVersion
            self.requestID = requestID
            self.ok = ok
            self.errorCode = errorCode
            self.message = message
            self.acceptedCount = acceptedCount
            self.jobIDs = jobIDs
            self.jobCount = jobCount
        }

        public static func failure(
            requestID: String,
            errorCode: String,
            message: String
        ) -> Response {
            Response(
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

    public static func decodeRequest(from body: Data) throws -> Request {
        let decoder = JSONDecoder()
        let request: Request
        do {
            request = try decoder.decode(Request.self, from: body)
        } catch {
            throw DecodeError.invalidJSON
        }
        guard request.protocolVersion == SchemaVersions.nativeMessaging else {
            throw DecodeError.unsupportedProtocolVersion(request.protocolVersion)
        }
        return request
    }

    public static func encodeResponse(_ response: Response) throws -> Data {
        try JSONEncoder().encode(response)
    }
}
