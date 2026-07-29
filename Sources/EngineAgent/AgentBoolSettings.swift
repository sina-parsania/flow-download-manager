// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Agent-process boolean preferences (UserDefaults). Keys are allowlisted for XPC.
public enum AgentBoolSettings {
    public static let zipAutoExtractEnabledKey = "zipAutoExtractEnabled"

    /// Sort completed downloads into a per-category folder (`Videos`, `Documents`, …)
    /// inside the download directory. Off by default: turning it on changes where
    /// files appear, which should be the user's decision, not an upgrade surprise.
    public static let categoryFoldersEnabledKey = "categoryFoldersEnabled"

    public static let allowlistedKeys: Set<String> = [
        zipAutoExtractEnabledKey,
        categoryFoldersEnabledKey
    ]

    /// Defaults: `zipAutoExtractEnabled` is true when never written (preserve prior behavior).
    public static func bool(
        forKey key: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard allowlistedKeys.contains(key) else { return false }
        if defaults.object(forKey: key) == nil {
            return defaultValue(forKey: key)
        }
        return defaults.bool(forKey: key)
    }

    public static func setBool(
        _ value: Bool,
        forKey key: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard allowlistedKeys.contains(key) else { return false }
        defaults.set(value, forKey: key)
        return true
    }

    public static func defaultValue(forKey key: String) -> Bool {
        switch key {
        case zipAutoExtractEnabledKey:
            return true
        default:
            return false
        }
    }
}
