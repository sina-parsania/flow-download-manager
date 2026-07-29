// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Maps a category stable key to the folder name downloads of that category land
/// in when "Create category folders" is on.
///
/// The stable keys are persistence tokens (`videos`, `documents`, …) and are never
/// localized — neither is the folder name. A user who turns the setting on, then
/// switches the system language, must not end up with two folders holding the same
/// category, and a path already written into a job's row must keep resolving.
public enum CategoryFolderName {
    /// Characters that cannot appear in a path component. `/` is the separator and
    /// `:` is what Finder shows as `/`; NUL terminates a C string. A category key
    /// containing any of these would silently create a nested or truncated folder.
    private static let forbidden: Set<Character> = ["/", ":", "\0"]

    /// The folder for `stableKey`, or `nil` when the key cannot make a safe path
    /// component. Callers treat `nil` as "write straight into the destination"
    /// rather than inventing a fallback folder.
    ///
    /// Today every key comes from the seeded catalogue and is a plain lowercase
    /// word, so this is title-casing. The guards exist because the value becomes a
    /// filesystem path, and `..` in particular would escape the download directory.
    public static func folderName(forCategoryStableKey stableKey: String) -> String? {
        let trimmed = stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        guard !trimmed.contains(where: { forbidden.contains($0) }) else { return nil }
        // `.` and `..` resolve to the destination itself or its parent.
        guard trimmed != ".", trimmed != ".." else { return nil }
        // A leading dot would hide the folder in Finder.
        guard !trimmed.hasPrefix(".") else { return nil }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}
