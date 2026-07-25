// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Classifies how an on-disk partial without a segment map should be handled
/// when range support is probed. File size alone is never proof of a contiguous
/// prefix — only explicit provenance (a valid `.segmap` or `existing < total`)
/// makes restart safe.
public enum PartialRestartPolicy: Sendable {
    public enum Classification: Equatable, Sendable {
        case freshDownload
        case resumeFromOffset(existing: Int64, total: Int64)
        case restartViaReplacement(existing: Int64, total: Int64)
        case ambiguousPreallocatedShell(total: Int64)
        case unknownRemoteTotal(existing: Int64)
    }

    /// Classifies a partial that has no authoritative `.segmap` sidecar.
    public static func classify(
        existingBytes: Int64,
        probe: TransferCore.ResourceIdentity
    ) -> Classification {
        guard existingBytes > 0 else { return .freshDownload }

        guard let total = TransferCore.totalLength(from: probe) else {
            return .unknownRemoteTotal(existing: existingBytes)
        }

        if existingBytes >= total {
            return .ambiguousPreallocatedShell(total: total)
        }

        if probe.httpStatus == 206 {
            return .resumeFromOffset(existing: existingBytes, total: total)
        }

        return .restartViaReplacement(existing: existingBytes, total: total)
    }
}
