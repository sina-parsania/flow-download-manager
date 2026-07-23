// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import TransferCurlBridge

/// Adaptive segmented HTTP download with verified single-stream fallback (FR-TRN-009).
public enum SegmentedTransfer {
    public struct Outcome: Sendable, Equatable {
        public let identity: TransferCore.ResourceIdentity
        public let bytesWritten: Int64
        public let segmentCount: Int
        public let partialURL: URL
    }

    /// Chooses segment count from content size. Small bodies stay single-stream.
    /// When `hostMaxSegments` is present (from a prior host observation), the
    /// size-based preference is clamped to that upper bound.
    public static func preferredSegmentCount(totalBytes: Int64, hostMaxSegments: Int? = nil) -> Int {
        let bySize: Int
        switch totalBytes {
        case ..<2048:
            bySize = 1
        case ..<16_777_216:
            bySize = 2
        case ..<67_108_864:
            bySize = 4
        default:
            let scaled = Int(totalBytes / (8 * 1024 * 1024))
            bySize = min(8, max(4, scaled))
        }
        guard let hostMaxSegments, hostMaxSegments > 0 else { return bySize }
        return min(bySize, hostMaxSegments)
    }

    public static func downloadHTTP(
        url: String,
        partialURL: URL,
        options: TransferCore.DownloadOptions = TransferCore.DownloadOptions(),
        abortFlag: TransferAbortFlag? = nil,
        onProgress: TransferCore.ProgressHandler? = nil,
        preferResume: Bool = true,
        hostMaxSegments: Int? = nil,
        useCurlMulti: Bool = true
    ) throws -> Outcome {
        if preferResume,
           let existing = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           existing > 0 {
            let resumed = try TransferCore.resumeOrDownload(
                url: url,
                partialURL: partialURL,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress
            )
            return Outcome(
                identity: resumed.identity,
                bytesWritten: resumed.bytesWritten,
                segmentCount: 1,
                partialURL: partialURL
            )
        }

        let probe = try TransferCore.probeRangeSupport(url: url, options: options)
        guard probe.httpStatus == 206, let total = TransferCore.totalLength(from: probe) else {
            return try singleOutcome(
                url: url, partialURL: partialURL, options: options,
                abortFlag: abortFlag, onProgress: onProgress
            )
        }

        let segments = preferredSegmentCount(totalBytes: total, hostMaxSegments: hostMaxSegments)
        guard segments > 1, total > 1 else {
            return try singleOutcome(
                url: url, partialURL: partialURL, options: options,
                abortFlag: abortFlag, onProgress: onProgress
            )
        }

        try preallocate(partialURL: partialURL, size: total)

        let segmentSize = total / Int64(segments)
        var rangeRequests: [CurlMultiLoop.RangeRequest] = []
        rangeRequests.reserveCapacity(segments)
        for index in 0 ..< segments {
            let start = Int64(index) * segmentSize
            let end = index == segments - 1 ? total - 1 : start + segmentSize - 1
            rangeRequests.append(
                CurlMultiLoop.RangeRequest(
                    rangeHeader: "\(start)-\(end)",
                    fileOffset: start,
                    expectedBytes: end - start + 1
                )
            )
        }

        if useCurlMulti {
            do {
                return try completeMultiDownload(
                    url: url,
                    partialURL: partialURL,
                    ranges: rangeRequests,
                    options: options,
                    abortFlag: abortFlag,
                    probe: probe,
                    total: total,
                    segments: segments
                )
            } catch TransferCore.TransferError.fileOpenFailed {
                // Recoverable multi setup failure — fall through to Dispatch once.
            }
        }

        let state = ConcurrentSegmentState(probe: probe, segmentCount: segments)
        let group = DispatchGroup()

        for index in 0 ..< segments {
            let start = Int64(index) * segmentSize
            let end = index == segments - 1 ? total - 1 : start + segmentSize - 1
            let expected = end - start + 1
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                if abortFlag?.isSet == true {
                    state.setError(TransferCore.TransferError.aborted)
                    return
                }
                let pieceProgress: TransferCore.ProgressHandler? = if let onProgress {
                    { written in
                        onProgress(state.recordProgress(segment: index, written: written))
                    }
                } else {
                    nil
                }
                do {
                    let piece = try TransferCore.downloadSingleStream(
                        url: url,
                        partialURL: partialURL,
                        rangeHeader: "\(start)-\(end)",
                        fileOffset: start,
                        options: options,
                        abortFlag: abortFlag,
                        onProgress: pieceProgress
                    )
                    guard piece.bytesWritten == expected else {
                        throw TransferCore.TransferError.incompleteWrite(
                            expected: expected,
                            wrote: piece.bytesWritten
                        )
                    }
                    state.setIdentity(piece.identity)
                } catch {
                    abortFlag?.requestAbort()
                    state.setError(error)
                }
            }
        }
        group.wait()
        if let firstError = state.firstError {
            throw firstError
        }
        let lastIdentity = state.identity

        let attrs = try FileManager.default.attributesOfItem(atPath: partialURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size == total else {
            throw TransferCore.TransferError.incompleteWrite(expected: total, wrote: size)
        }

        return Outcome(
            identity: TransferCore.ResourceIdentity(
                finalURL: lastIdentity.finalURL,
                contentLength: total,
                contentType: lastIdentity.contentType ?? probe.contentType,
                etag: lastIdentity.etag ?? probe.etag,
                lastModified: lastIdentity.lastModified ?? probe.lastModified,
                acceptRanges: probe.acceptRanges,
                contentDisposition: lastIdentity.contentDisposition ?? probe.contentDisposition,
                contentRange: lastIdentity.contentRange,
                httpStatus: lastIdentity.httpStatus
            ),
            bytesWritten: size,
            segmentCount: segments,
            partialURL: partialURL
        )
    }

    private static func completeMultiDownload(
        url: String,
        partialURL: URL,
        ranges: [CurlMultiLoop.RangeRequest],
        options: TransferCore.DownloadOptions,
        abortFlag: TransferAbortFlag?,
        probe: TransferCore.ResourceIdentity,
        total: Int64,
        segments: Int
    ) throws -> Outcome {
        _ = try TransferCore.downloadRangesViaMulti(
            url: url,
            partialURL: partialURL,
            ranges: ranges,
            options: options,
            abortFlag: abortFlag
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: partialURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size == total else {
            throw TransferCore.TransferError.incompleteWrite(expected: total, wrote: size)
        }
        return Outcome(
            identity: TransferCore.ResourceIdentity(
                finalURL: probe.finalURL,
                contentLength: total,
                contentType: probe.contentType,
                etag: probe.etag,
                lastModified: probe.lastModified,
                acceptRanges: probe.acceptRanges,
                contentDisposition: probe.contentDisposition,
                contentRange: nil,
                httpStatus: 206
            ),
            bytesWritten: size,
            segmentCount: segments,
            partialURL: partialURL
        )
    }

    private static func singleOutcome(
        url: String,
        partialURL: URL,
        options: TransferCore.DownloadOptions,
        abortFlag: TransferAbortFlag?,
        onProgress: TransferCore.ProgressHandler?
    ) throws -> Outcome {
        let single = try TransferCore.downloadSingleStream(
            url: url,
            partialURL: partialURL,
            options: options,
            abortFlag: abortFlag,
            onProgress: onProgress
        )
        return Outcome(
            identity: single.identity,
            bytesWritten: single.bytesWritten,
            segmentCount: 1,
            partialURL: partialURL
        )
    }

    private static func preallocate(partialURL: URL, size: Int64) throws {
        let directory = partialURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }
        let fd = partialURL.path.withCString { path in
            open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard fd >= 0 else { throw TransferCore.TransferError.fileOpenFailed }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw TransferCore.TransferError.fileOpenFailed
        }
    }
}

private final class ConcurrentSegmentState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastIdentity: TransferCore.ResourceIdentity
    private var error: Error?
    private var progressBySegment: [Int64]

    init(probe: TransferCore.ResourceIdentity, segmentCount: Int) {
        lastIdentity = probe
        progressBySegment = Array(repeating: 0, count: segmentCount)
    }

    var identity: TransferCore.ResourceIdentity {
        lock.lock()
        defer { lock.unlock() }
        return lastIdentity
    }

    var firstError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func setIdentity(_ identity: TransferCore.ResourceIdentity) {
        lock.lock()
        lastIdentity = identity
        lock.unlock()
    }

    func setError(_ error: Error) {
        lock.lock()
        if self.error == nil {
            self.error = error
        }
        lock.unlock()
    }

    func recordProgress(segment: Int, written: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if segment >= 0, segment < progressBySegment.count {
            progressBySegment[segment] = written
        }
        return progressBySegment.reduce(0, +)
    }
}
