// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Resolve a destination-profile security-scoped bookmark to a directory URL.
public enum DestinationBookmark {
    public static func resolveDirectory(bookmarkData: Data) throws -> URL {
        var isStale = false
        do {
            return try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            return try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
    }

    public static func pathDisplay(bookmarkData: Data) -> String? {
        (try? resolveDirectory(bookmarkData: bookmarkData))?.path
    }
}
