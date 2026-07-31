// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Decides whether a fresh download should skip the ranged probe.
///
/// Kept small and pure so unit tests can pin the heuristics without standing up
/// curl. Callers still own the transfer; this only answers "probe or not".
public enum RangeProbePolicy: Sendable {
    /// Cookie-bearing jobs and fragile signed query strings skip the probe so a
    /// `Range: 0-0` GET cannot consume the only allowed download. Cloud object
    /// stores that honour Range on signed URLs are exempt — multi-segment must
    /// keep working there.
    public static func shouldSkipProbe(
        url: String,
        options: TransferCore.DownloadOptions
    ) -> Bool {
        if hasFragileCredentials(options) { return true }
        return looksLikeFragileSignedURL(url)
    }

    /// Non-empty Cookie, Authorization, userpwd, or cookie-jar path.
    public static func hasFragileCredentials(_ options: TransferCore.DownloadOptions) -> Bool {
        if let userpwd = options.userpwd, !userpwd.isEmpty { return true }
        if let cookieJarPath = options.cookieJarPath, !cookieJarPath.isEmpty { return true }
        return options.extraHeaders.contains { header in
            guard !header.value.isEmpty else { return false }
            return header.name.compare("Cookie", options: [.caseInsensitive]) == .orderedSame
                || header.name.compare("Authorization", options: [.caseInsensitive]) == .orderedSame
        }
    }

    /// Signature-like query without a Range-friendly cloud-storage shape.
    public static func looksLikeFragileSignedURL(_ urlString: String) -> Bool {
        guard let keys = queryKeySet(urlString), !keys.isEmpty else { return false }

        // Range-capable signed object storage — keep the probe (and segmentation).
        if keys.contains(where: { $0.hasPrefix("x-amz-") }) { return false }
        if keys.contains(where: { $0.hasPrefix("x-goog-") }) { return false }
        if keys.contains("sig"), keys.contains("sv") { return false }

        let signatureKeys: Set<String> = [
            "sig", "signature", "sign", "signed",
            "auth_key", "authkey", "download_token", "downloadtoken",
            "verify", "hmac"
        ]
        if !keys.isDisjoint(with: signatureKeys) { return true }

        // Expiry alone is too common on ordinary CDNs; require a token-ish peer.
        let tokenKeys: Set<String> = ["token", "key", "hash"]
        return !keys.isDisjoint(with: expiryKeys) && !keys.isDisjoint(with: tokenKeys)
    }

    /// A fragile URL that also carries an explicit expiry.
    ///
    /// The distinction matters because the two fragile shapes carry different
    /// risks. A one-shot token is consumed by the first GET, so it gets exactly
    /// one unranged request and no parallelism — that is not negotiable. An
    /// **expiring** signature is by construction re-fetchable until it expires,
    /// so its opening chunk may be ranged and the download may segment.
    ///
    /// Without an expiry key nothing can be concluded, and the conservative
    /// single-request path is kept.
    public static func hasExplicitExpiry(_ urlString: String) -> Bool {
        guard let keys = queryKeySet(urlString) else { return false }
        return !keys.isDisjoint(with: expiryKeys)
    }

    private static let expiryKeys: Set<String> = ["expires", "expiry", "expire", "exp"]

    private static func queryKeySet(_ urlString: String) -> Set<String>? {
        guard let components = URLComponents(string: urlString),
              let items = components.queryItems,
              !items.isEmpty
        else { return nil }
        return Set(items.map { $0.name.lowercased() })
    }
}
