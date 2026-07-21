// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security
import XPCSecuritySupport

/// Validates the identity of a process connecting to the engine's XPC listener.
///
/// Authorization uses the connecting process's audit token and code signature,
/// never a caller-supplied role (`04-domain-and-data-contracts.md` §9,
/// `06-licensing-security-privacy.md` §4). The protocol is a seam so tests can
/// exercise both the authorized and rejected paths deterministically.
public protocol ClientIdentityValidator: Sendable {
    func isAuthorized(_ connection: NSXPCConnection) -> Bool
}

/// Production validator: derives a `SecCode` from the peer's audit token and
/// checks it against a `SecRequirement`.
///
/// The default requirement matches an allowlisted signing identifier, which holds
/// even under local ad-hoc signing (the app's `identifier` is present without a
/// Developer ID anchor). The release owner supplies a stronger requirement
/// (adding `anchor apple generic` and the team identifier) in the signed
/// environment; the requirement string is therefore injectable.
public struct CodeSigningIdentityValidator: ClientIdentityValidator {
    public let requirement: String

    /// Build a validator from an explicit requirement string.
    public init(requirement: String) {
        self.requirement = requirement
    }

    /// Convenience: require the peer's code-signing identifier to be one of
    /// `allowedIdentifiers`.
    public init(allowedIdentifiers: [String]) {
        let clause = allowedIdentifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        requirement = allowedIdentifiers.isEmpty ? "never" : clause
    }

    public func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        var token = auditToken(for: connection)
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else { return false }

        var requirementRef: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &requirementRef) == errSecSuccess,
              let requirementRef
        else { return false }

        // Checks both a valid signature and the requirement in one call.
        return SecCodeCheckValidity(code, [], requirementRef) == errSecSuccess
    }
}
