// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Filesystem presence for the relative partial/final names recorded in a
/// finalization intent. Absolute paths are resolved by the caller.
public enum FinalizationFilesystemSnapshot: Equatable, Sendable {
    case partialOnly(partialSize: Int64)
    case finalOnly(finalSize: Int64)
    case both(partialSize: Int64, finalSize: Int64)
    case neither
}

/// Pure reconciliation plan from intent stage + on-disk artifacts.
public enum FinalizationReconciliationPlan: Equatable, Sendable {
    /// Resume checksum verification and atomic promotion.
    case resumePromotion
    /// Final file is already on disk; advance to post-processing.
    case advanceToPostProcessing
    /// Final file is valid and no post-processing is required.
    case completeWithoutPostProcessing
    /// Final file is valid; run optional post-processing (e.g. ZIP extract).
    case runPostProcessing
    /// Neither artifact is present.
    case failMissingArtifacts
    /// Partial and final both exist — do not delete either.
    case failAmbiguousFiles
    /// On-disk size does not match the durable intent.
    case failSizeMismatch(expected: Int64, actual: Int64)
    /// Job already completed; only the intent row needs cleanup.
    case cleanupIntentOnly
}

/// Value-type view of a persisted finalization intent for reconciliation.
public struct FinalizationIntentSnapshot: Equatable, Sendable {
    public let stage: FinalizationIntentStage
    public let expectedByteSize: Int64
    public let zipAutoExtract: Bool

    public init(
        stage: FinalizationIntentStage,
        expectedByteSize: Int64,
        zipAutoExtract: Bool
    ) {
        self.stage = stage
        self.expectedByteSize = expectedByteSize
        self.zipAutoExtract = zipAutoExtract
    }
}

/// Idempotent filesystem reconciliation for interrupted finalization.
public enum FinalizationReconciler {
    public static func plan(
        intent: FinalizationIntentSnapshot,
        snapshot: FinalizationFilesystemSnapshot
    ) -> FinalizationReconciliationPlan {
        switch (intent.stage, snapshot) {
        case let (.prepared, .partialOnly(size)):
            return sizeMatches(intent.expectedByteSize, size)
                ? .resumePromotion
                : .failSizeMismatch(expected: intent.expectedByteSize, actual: size)

        case let (.prepared, .finalOnly(size)):
            return sizeMatches(intent.expectedByteSize, size)
                ? postProcessingPlan(zipAutoExtract: intent.zipAutoExtract)
                : .failSizeMismatch(expected: intent.expectedByteSize, actual: size)

        case let (.prepared, .both(partialSize, finalSize)):
            if !sizeMatches(intent.expectedByteSize, partialSize)
                || !sizeMatches(intent.expectedByteSize, finalSize) {
                let actual = partialSize != intent.expectedByteSize ? partialSize : finalSize
                return .failSizeMismatch(expected: intent.expectedByteSize, actual: actual)
            }
            return .failAmbiguousFiles

        case (.prepared, .neither):
            return .failMissingArtifacts

        case let (.promoted, .finalOnly(size)):
            return sizeMatches(intent.expectedByteSize, size)
                ? postProcessingPlan(zipAutoExtract: intent.zipAutoExtract)
                : .failSizeMismatch(expected: intent.expectedByteSize, actual: size)

        case let (.promoted, .partialOnly(size)):
            if !sizeMatches(intent.expectedByteSize, size) {
                return .failSizeMismatch(expected: intent.expectedByteSize, actual: size)
            }
            return .failAmbiguousFiles

        case let (.promoted, .both(partialSize, finalSize)):
            if !sizeMatches(intent.expectedByteSize, partialSize)
                || !sizeMatches(intent.expectedByteSize, finalSize) {
                let actual = partialSize != intent.expectedByteSize ? partialSize : finalSize
                return .failSizeMismatch(expected: intent.expectedByteSize, actual: actual)
            }
            return .failAmbiguousFiles

        case (.promoted, .neither):
            return .failMissingArtifacts
        }
    }

    public static func filesystemSnapshot(
        partialURL: URL,
        finalURL: URL
    ) -> FinalizationFilesystemSnapshot {
        let partialExists = FileManager.default.fileExists(atPath: partialURL.path)
        let finalExists = FileManager.default.fileExists(atPath: finalURL.path)
        let partialSize = partialExists ? fileSize(at: partialURL) : nil
        let finalSize = finalExists ? fileSize(at: finalURL) : nil

        switch (partialExists, finalExists) {
        case (true, false):
            return .partialOnly(partialSize: partialSize ?? -1)
        case (false, true):
            return .finalOnly(finalSize: finalSize ?? -1)
        case (true, true):
            return .both(
                partialSize: partialSize ?? -1,
                finalSize: finalSize ?? -1
            )
        case (false, false):
            return .neither
        }
    }

    private static func postProcessingPlan(zipAutoExtract: Bool) -> FinalizationReconciliationPlan {
        zipAutoExtract ? .runPostProcessing : .completeWithoutPostProcessing
    }

    private static func sizeMatches(_ expected: Int64, _ actual: Int64) -> Bool {
        expected >= 0 && actual == expected
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else {
            return nil
        }
        return Int64(size)
    }
}
