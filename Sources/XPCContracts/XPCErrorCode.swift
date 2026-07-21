// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Stable error domain for the XPC control interface. Raw underlying diagnostics
/// (OSStatus, errno) are nested in `userInfo`, never the public contract
/// (`04-domain-and-data-contracts.md` §5).
public let XPCErrorDomain = "org.downloadmanager.local.xpc"

/// Typed, stable XPC failure codes. New cases are appended; existing raw values
/// never change.
@objc(DMXPCErrorCode)
public enum XPCErrorCode: Int, Sendable {
    case unsupportedProtocolVersion = 1
    case handshakeRequired = 2
    case unauthorizedClient = 3
    case duplicateRequestID = 4
    case invalidPayload = 5
    case payloadTooLarge = 6
    case internalError = 7

    public var message: String {
        switch self {
        case .unsupportedProtocolVersion: return "Unsupported XPC protocol version."
        case .handshakeRequired: return "A successful handshake is required before this command."
        case .unauthorizedClient: return "The connecting process failed identity validation."
        case .duplicateRequestID: return "A non-idempotent request ID was replayed."
        case .invalidPayload: return "The request payload failed validation."
        case .payloadTooLarge: return "The request payload exceeded the allowed size."
        case .internalError: return "The engine encountered an internal error."
        }
    }

    /// Build an `NSError` in ``XPCErrorDomain`` carrying this code and message.
    /// A sanitized detail may be attached; secrets/paths must already be redacted
    /// by the caller.
    public func error(detail: String? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let detail { info["detail"] = detail }
        return NSError(domain: XPCErrorDomain, code: rawValue, userInfo: info)
    }
}
