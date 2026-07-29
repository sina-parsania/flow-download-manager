// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Length-bounded decode helpers for the XPC trust boundary.
///
/// Every DTO decoder here reads attacker-controllable bytes, so every string it
/// accepts needs a ceiling. Writing that ceiling by hand once per field is how
/// they drift: `PullJobChangesRequest` and `JobChangeBatch` decoded `requestID`
/// with no cap at all while every sibling DTO capped it. These helpers make the
/// bound the default — you have to pass a length to get anything else, and you
/// cannot get *no* bound.
public extension NSCoder {
    /// Decodes a non-empty string no longer than `maxLength` UTF-16 units.
    /// Returns `nil` when the key is absent, empty, or over the ceiling, so a
    /// caller's `guard let` fails the whole decode — which is what secure coding
    /// expects on malformed input.
    func decodeBoundedString(
        _ key: String,
        maxLength: Int = EngineXPC.maxPayloadStringLength
    ) -> String? {
        guard let value = decodeObject(of: NSString.self, forKey: key) else { return nil }
        guard value.length > 0, value.length <= maxLength else { return nil }
        return value as String
    }

    /// Decodes a string that must parse as a UUID. Used for every identifier that
    /// crosses the boundary — job, batch, profile, request.
    func decodeUUIDString(_ key: String) -> String? {
        guard let value = decodeBoundedString(key, maxLength: 36) else { return nil }
        guard UUID(uuidString: value) != nil else { return nil }
        return value
    }

    /// Decodes an optional string: absent is a valid `nil`, but a present value
    /// over the ceiling is still a decode failure rather than a silent truncation.
    /// The double optional distinguishes the two — `nil` means reject,
    /// `.some(nil)` means the field was legitimately absent.
    func decodeOptionalBoundedString(
        _ key: String,
        maxLength: Int = EngineXPC.maxPayloadStringLength
    ) -> String?? {
        guard let value = decodeObject(of: NSString.self, forKey: key) else { return .some(nil) }
        guard value.length <= maxLength else { return nil }
        return .some(value as String)
    }
}
