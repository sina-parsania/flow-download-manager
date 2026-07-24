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
        case ..<1_048_576: // < 1 MiB
            bySize = 1
        case ..<8_388_608: // < 8 MiB
            bySize = 2
        case ..<33_554_432: // < 32 MiB
            bySize = 4
        case ..<134_217_728: // < 128 MiB
            bySize = 8
        default:
            // Large files: up to 32 parallel ranges (IDM-class aggressive default).
            let scaled = Int(totalBytes / (4 * 1024 * 1024))
            bySize = min(32, max(8, scaled))
        }
        guard let hostMaxSegments, hostMaxSegments > 0 else { return bySize }
        return min(bySize, hostMaxSegments)
    }

    /// Ledger chunk count (FR-TRN-009 S1). Chunks are ~4 MiB, never fewer than
    /// `connectionCount`, and `connectionCount` still bounds how many are live.
    ///
    /// **Tile size is what bounds a straggler's damage.** A slow connection
    /// holds exactly one chunk, so the tail costs `chunkSize / slowRate`
    /// regardless of how many connections are running. The cap was 128, which
    /// silently abandoned that property on anything large: a 4 GiB file tiled
    /// into 32 MiB chunks, a 40 GiB file into 320 MiB chunks, so the last
    /// connection to finish held a quarter-gigabyte on its own. 1024 keeps
    /// chunks at the 4 MiB floor out to 4 GiB and an order of magnitude finer
    /// beyond it, for ~40 KB of extra `.segmap` JSON at the very top end.
    ///
    /// This bounds the tail; it does not redistribute work already in flight.
    /// Taking the tail off a *live* connection needs a safe-zone split, which
    /// libcurl's fixed `Range:` request makes a protocol change, not a tuning
    /// change.
    static func chunkCount(from start: Int64, total: Int64, connectionCount: Int) -> Int {
        let minChunk: Int64 = 4 * 1024 * 1024
        let maxChunks = 1024
        let span = total - start
        guard span > 0 else { return max(connectionCount, 1) }
        let byMinChunk = Int((span + minChunk - 1) / minChunk)
        return max(connectionCount, min(maxChunks, byMinChunk))
    }

    /// Sidecar path recording which byte ranges of the partial are actually on
    /// disk. The partial's file size is meaningless once preallocated.
    public static func segmentMapURL(for partialURL: URL) -> URL {
        URL(fileURLWithPath: partialURL.path + ".segmap")
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
        // Range probing, segment maps and the 200/206 status gate are all HTTP
        // semantics. FTP/SFTP were accepted by the UI and then run through this
        // path anyway, so every one of them failed once with a misleading
        // "network unavailable". They take the single-stream path instead.
        if let parsed = try? CurlURLParser.parse(url), !parsed.isHTTPFamily {
            return try singleOutcome(
                url: url, partialURL: partialURL, options: options,
                abortFlag: abortFlag, onProgress: onProgress
            )
        }

        let sidecarURL = segmentMapURL(for: partialURL)

        // Segment-map resume: the authoritative record of downloaded ranges.
        if preferResume, let ledger = SegmentLedger.load(sidecarURL: sidecarURL) {
            let partialSize = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize.map(Int64.init) ?? 0
            if partialSize == ledger.total {
                // Probe live. A transient probe failure (network down at relaunch,
                // 5xx/429, etc.) MUST NOT discard the partial — propagate the error
                // so the job's retry/requeue path keeps the bytes on disk and
                // resumes later.
                let probe = try TransferCore.probeRangeSupport(url: url, options: options)
                if probe.httpStatus == 206,
                   TransferCore.totalLength(from: probe) == ledger.total {
                    let connectionCount = preferredSegmentCount(
                        totalBytes: ledger.remainingBytes(),
                        hostMaxSegments: hostMaxSegments
                    )
                    return try runMapLoop(
                        url: url,
                        partialURL: partialURL,
                        ledger: ledger,
                        options: options,
                        abortFlag: abortFlag,
                        onProgress: onProgress,
                        probe: probe,
                        useCurlMulti: useCurlMulti,
                        maxConcurrent: connectionCount,
                        hostMaxSegments: hostMaxSegments
                    )
                }
                // Probe reached the server but disagreed. Only wipe when the
                // remote length is known and clearly different; a 200/non-206
                // with the same (or unknown) length is treated as transient so
                // we keep the map + partial for the next attempt.
                if let remoteTotal = TransferCore.totalLength(from: probe),
                   remoteTotal != ledger.total {
                    try? FileManager.default.removeItem(at: sidecarURL)
                    try? FileManager.default.removeItem(at: partialURL)
                } else {
                    throw TransferCore.TransferError.httpStatus(probe.httpStatus)
                }
            } else {
                // Local size disagrees with the map — unusable. Start clean.
                try? FileManager.default.removeItem(at: sidecarURL)
                try? FileManager.default.removeItem(at: partialURL)
            }
        }

        let existing = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0

        // Legacy contiguous-prefix partial (single-stream era): fill the tail
        // with multiple connections when the server allows ranges.
        if preferResume, existing > 0 {
            if let multi = try? resumeWithSegments(
                url: url,
                partialURL: partialURL,
                existing: existing,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress,
                hostMaxSegments: hostMaxSegments,
                useCurlMulti: useCurlMulti
            ) {
                return multi
            }
            // Preallocated segmented shells have fileSize == Content-Length even
            // when most ranges are empty. Without a segmap, size is not a safe
            // contiguous-prefix signal — never wipe and restart from 0 here.
            if let probe = try? TransferCore.probeRangeSupport(url: url, options: options),
               let total = TransferCore.totalLength(from: probe),
               existing >= total {
                throw TransferCore.TransferError.incompleteWrite(expected: total, wrote: 0)
            }
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

        let connectionCount = preferredSegmentCount(totalBytes: total, hostMaxSegments: hostMaxSegments)
        guard connectionCount > 1, total > 1 else {
            return try singleOutcome(
                url: url, partialURL: partialURL, options: options,
                abortFlag: abortFlag, onProgress: onProgress
            )
        }

        let chunks = chunkCount(from: 0, total: total, connectionCount: connectionCount)
        let ledger = SegmentLedger(
            total: total,
            baseOffset: 0,
            entries: tile(from: 0, total: total, count: chunks),
            sidecarURL: sidecarURL
        )
        // Save the map before preallocating: once the file is truncated to
        // `total`, only the map can say what is really on disk.
        try ledger.saveNow()
        try preallocate(partialURL: partialURL, size: total)

        return try runMapLoop(
            url: url,
            partialURL: partialURL,
            ledger: ledger,
            options: options,
            abortFlag: abortFlag,
            onProgress: onProgress,
            probe: probe,
            useCurlMulti: useCurlMulti,
            maxConcurrent: connectionCount,
            hostMaxSegments: hostMaxSegments
        )
    }

    /// Multi-connection download of bytes `[existing, total)` into an existing partial.
    private static func resumeWithSegments(
        url: String,
        partialURL: URL,
        existing: Int64,
        options: TransferCore.DownloadOptions,
        abortFlag: TransferAbortFlag?,
        onProgress: TransferCore.ProgressHandler?,
        hostMaxSegments: Int?,
        useCurlMulti: Bool
    ) throws -> Outcome {
        let probe = try TransferCore.probeRangeSupport(url: url, options: options)
        guard probe.httpStatus == 206,
              let total = TransferCore.totalLength(from: probe),
              existing < total
        else {
            throw TransferCore.TransferError.httpStatus(probe.httpStatus)
        }

        let remaining = total - existing
        let connectionCount = preferredSegmentCount(totalBytes: remaining, hostMaxSegments: hostMaxSegments)
        guard connectionCount > 1 else {
            throw TransferCore.TransferError.httpStatus(probe.httpStatus)
        }

        let chunks = chunkCount(from: existing, total: total, connectionCount: connectionCount)
        let ledger = SegmentLedger(
            total: total,
            baseOffset: existing,
            entries: tile(from: existing, total: total, count: chunks),
            sidecarURL: segmentMapURL(for: partialURL)
        )
        try ledger.saveNow()
        try preallocate(partialURL: partialURL, size: total)

        return try runMapLoop(
            url: url,
            partialURL: partialURL,
            ledger: ledger,
            options: options,
            abortFlag: abortFlag,
            onProgress: onProgress,
            probe: probe,
            useCurlMulti: useCurlMulti,
            maxConcurrent: connectionCount,
            hostMaxSegments: hostMaxSegments
        )
    }

    /// Drives the segment map to completion: run remaining ranges, retry
    /// transient failures with backoff, and re-split what is left so a stalled
    /// tail regains parallelism (bounded dynamic re-segmentation).
    private static func runMapLoop(
        url: String,
        partialURL: URL,
        ledger: SegmentLedger,
        options: TransferCore.DownloadOptions,
        abortFlag: TransferAbortFlag?,
        onProgress: TransferCore.ProgressHandler?,
        probe: TransferCore.ResourceIdentity,
        useCurlMulti: Bool,
        maxConcurrent: Int,
        hostMaxSegments: Int? = nil
    ) throws -> Outcome {
        // Publish already-downloaded bytes immediately so relaunch UI does not
        // flash 0% before the first curl progress callback.
        onProgress?(ledger.baseOffset + ledger.downloadedBytes())
        // ONE governor for the whole job, fed the ledger's aggregate byte count.
        // The per-easy governor inside `downloadSingleStream` cannot cap a
        // segmented transfer: the curl_multi transport never goes through it at
        // all, and the Dispatch fallback would build one bucket per segment,
        // each allowed the full rate. Segment options below have the cap
        // stripped so this is the only thing throttling.
        let governor: SyncBandwidthGovernor? = options.maxBytesPerSecond > 0
            ? SyncBandwidthGovernor(bytesPerSecond: options.maxBytesPerSecond)
            : nil
        var segmentOptions = options
        segmentOptions.maxBytesPerSecond = 0
        let maxAttempts = 3
        var attempt = 0
        // Host-clamped connection cap for the live multi loop. Chunk count in
        // the ledger may be finer (S1 tiling); this only bounds concurrency.
        var connectionLimit = maxConcurrent
        while true {
            if abortFlag?.isSet == true {
                ledger.flush()
                throw TransferCore.TransferError.aborted
            }
            let remaining = ledger.remainingWork()
            if remaining.isEmpty { break }
            let entryIndices = remaining.map(\.entryIndex)
            let bases = remaining.map(\.baseWritten)
            let progressOffset = ledger.baseOffset
            do {
                try runSegmentedRanges(
                    url: url,
                    partialURL: partialURL,
                    ranges: remaining.map(\.request),
                    options: segmentOptions,
                    abortFlag: abortFlag,
                    useCurlMulti: useCurlMulti,
                    maxConcurrent: connectionLimit,
                    onSegmentProgress: { segment, written in
                        guard segment >= 0, segment < entryIndices.count else { return }
                        let done = ledger.record(
                            entry: entryIndices[segment],
                            written: bases[segment] + written
                        )
                        onProgress?(progressOffset + done)
                        // `done` is the job's cumulative total, so one governor
                        // sees the aggregate rate across every live segment.
                        // On the curl_multi transport this callback runs on the
                        // single multi thread, so sleeping here throttles all
                        // segments at once — which is exactly the intent.
                        governor?.noteProgress(totalWritten: done)
                    }
                )
                // Both transports verified expected byte counts per range.
                ledger.markCompleted(entryIndices: entryIndices)
            } catch {
                ledger.flush()
                if abortFlag?.isSet == true { throw TransferCore.TransferError.aborted }
                if case TransferCore.TransferError.aborted = error { throw error }
                attempt += 1
                guard attempt < maxAttempts else { throw error }
                Thread.sleep(forTimeInterval: Double(attempt))
                connectionLimit = preferredSegmentCount(
                    totalBytes: ledger.remainingBytes(),
                    hostMaxSegments: hostMaxSegments
                )
                ledger.resplit(targetCount: connectionLimit)
            }
        }

        try synchronizeFile(at: partialURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: partialURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size == ledger.total else {
            throw TransferCore.TransferError.incompleteWrite(expected: ledger.total, wrote: size)
        }
        ledger.deleteSidecar()

        return Outcome(
            identity: TransferCore.ResourceIdentity(
                finalURL: probe.finalURL,
                contentLength: ledger.total,
                contentType: probe.contentType,
                etag: probe.etag,
                lastModified: probe.lastModified,
                acceptRanges: probe.acceptRanges,
                contentDisposition: probe.contentDisposition,
                contentRange: nil,
                httpStatus: 206
            ),
            bytesWritten: size,
            segmentCount: ledger.entryCount,
            partialURL: partialURL
        )
    }

    /// One pass over the given ranges: curl_multi preferred, Dispatch threads
    /// as the recoverable fallback. Throws the first range failure; siblings
    /// run to completion and their bytes stay recorded in the segment map.
    private static func runSegmentedRanges(
        url: String,
        partialURL: URL,
        ranges: [CurlMultiLoop.RangeRequest],
        options: TransferCore.DownloadOptions,
        abortFlag: TransferAbortFlag?,
        useCurlMulti: Bool,
        maxConcurrent: Int? = nil,
        onSegmentProgress: (@Sendable (Int, Int64) -> Void)?
    ) throws {
        if useCurlMulti {
            do {
                _ = try TransferCore.downloadRangesViaMulti(
                    url: url,
                    partialURL: partialURL,
                    ranges: ranges,
                    options: options,
                    abortFlag: abortFlag,
                    onSegmentProgress: onSegmentProgress,
                    maxConcurrent: maxConcurrent
                )
                return
            } catch TransferCore.TransferError.fileOpenFailed {
                // Recoverable multi setup failure — fall through to Dispatch once.
            }
        }

        let state = ConcurrentSegmentState()
        let group = DispatchGroup()
        // The ledger tiles into far more chunks than there are connections
        // (up to 128). Without this bound the fallback would open one socket
        // per chunk and blow straight past the orchestrator's host budget.
        let slots = DispatchSemaphore(value: max(1, min(maxConcurrent ?? ranges.count, ranges.count)))

        for (index, range) in ranges.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                slots.wait()
                defer {
                    slots.signal()
                    group.leave()
                }
                if abortFlag?.isSet == true {
                    state.setError(TransferCore.TransferError.aborted)
                    return
                }
                let pieceProgress: TransferCore.ProgressHandler? =
                    if let report = onSegmentProgress {
                        { written in report(index, written) }
                    } else {
                        nil
                    }
                do {
                    let piece = try TransferCore.downloadSingleStream(
                        url: url,
                        partialURL: partialURL,
                        rangeHeader: range.rangeHeader,
                        fileOffset: range.fileOffset,
                        options: options,
                        abortFlag: abortFlag,
                        onProgress: pieceProgress
                    )
                    guard piece.bytesWritten == range.expectedBytes else {
                        throw TransferCore.TransferError.incompleteWrite(
                            expected: range.expectedBytes ?? -1,
                            wrote: piece.bytesWritten
                        )
                    }
                } catch {
                    state.setError(error)
                }
            }
        }
        group.wait()
        if let firstError = state.firstError {
            throw firstError
        }
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
        try synchronizeFile(at: partialURL)
        return Outcome(
            identity: single.identity,
            bytesWritten: single.bytesWritten,
            segmentCount: 1,
            partialURL: partialURL
        )
    }

    /// One durable flush after the transfer finishes. Per-easy fsync in C was
    /// removed so multi-segment jobs do not serialize N full-file syncs.
    private static func synchronizeFile(at url: URL) throws {
        let fd = url.path.withCString { path in
            open(path, O_WRONLY)
        }
        guard fd >= 0 else { throw TransferCore.TransferError.fileOpenFailed }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw TransferCore.TransferError.fileOpenFailed
        }
    }

    /// Splits `[start, total)` into `count` contiguous entries.
    private static func tile(from start: Int64, total: Int64, count: Int) -> [SegmentLedger.Entry] {
        let span = total - start
        let size = span / Int64(count)
        return (0 ..< count).map { index in
            let entryStart = start + Int64(index) * size
            let entryEnd = index == count - 1 ? total - 1 : entryStart + size - 1
            return SegmentLedger.Entry(start: entryStart, end: entryEnd, written: 0)
        }
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

/// Persisted per-segment progress map. Lives as a `.segmap` sidecar next to the
/// partial; deleted on success. In-memory updates on every progress callback,
/// disk writes throttled to once per second plus explicit flushes.
final class SegmentLedger: @unchecked Sendable {
    struct Entry: Codable, Sendable {
        var start: Int64
        var end: Int64 // inclusive
        var written: Int64
    }

    private struct MapFile: Codable {
        var total: Int64
        var baseOffset: Int64
        var entries: [Entry]
    }

    let total: Int64
    /// Bytes on disk before the mapped region (legacy contiguous-prefix resume).
    let baseOffset: Int64

    private let sidecarURL: URL
    private let lock = NSLock()
    private var entries: [Entry]
    private var lastSaveNanos: UInt64 = 0

    init(total: Int64, baseOffset: Int64, entries: [Entry], sidecarURL: URL) {
        self.total = total
        self.baseOffset = baseOffset
        self.entries = entries
        self.sidecarURL = sidecarURL
    }

    static func load(sidecarURL: URL) -> SegmentLedger? {
        guard let data = try? Data(contentsOf: sidecarURL),
              let file = try? JSONDecoder().decode(MapFile.self, from: data),
              file.total > 0,
              file.baseOffset >= 0,
              !file.entries.isEmpty,
              file.entries.allSatisfy({ entry in
                  entry.start >= 0 && entry.end < file.total && entry.start <= entry.end
                      && entry.written >= 0 && entry.written <= entry.end - entry.start + 1
              })
        else { return nil }
        return SegmentLedger(
            total: file.total,
            baseOffset: file.baseOffset,
            entries: file.entries,
            sidecarURL: sidecarURL
        )
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    struct Work {
        let entryIndex: Int
        let baseWritten: Int64
        let request: CurlMultiLoop.RangeRequest
    }

    func remainingWork() -> [Work] {
        lock.lock()
        defer { lock.unlock() }
        return entries.enumerated().compactMap { index, entry in
            let start = entry.start + entry.written
            guard start <= entry.end else { return nil }
            return Work(
                entryIndex: index,
                baseWritten: entry.written,
                request: CurlMultiLoop.RangeRequest(
                    rangeHeader: "\(start)-\(entry.end)",
                    fileOffset: start,
                    expectedBytes: entry.end - start + 1
                )
            )
        }
    }

    func remainingBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return entries.reduce(Int64(0)) { $0 + ($1.end - $1.start + 1 - $1.written) }
    }

    func downloadedBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return entries.reduce(Int64(0)) { $0 + $1.written }
    }

    /// Records cumulative progress for one entry; returns completed bytes
    /// across all entries. Persists at most once per second.
    func record(entry index: Int, written: Int64) -> Int64 {
        lock.lock()
        if index >= 0, index < entries.count {
            let capacity = entries[index].end - entries[index].start + 1
            entries[index].written = min(max(entries[index].written, written), capacity)
        }
        let done = entries.reduce(Int64(0)) { $0 + $1.written }
        let now = DispatchTime.now().uptimeNanoseconds
        var snapshot: MapFile?
        if now &- lastSaveNanos >= 1_000_000_000 {
            lastSaveNanos = now
            snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries)
        }
        lock.unlock()
        if let snapshot { write(snapshot) }
        return done
    }

    func markCompleted(entryIndices: [Int]) {
        lock.lock()
        for index in entryIndices where index >= 0 && index < entries.count {
            entries[index].written = entries[index].end - entries[index].start + 1
        }
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries)
        lock.unlock()
        write(snapshot)
    }

    /// Splits the largest remaining ranges until `targetCount` incomplete
    /// entries exist (or chunks would drop below 4 MiB). Called between retry
    /// attempts so leftover bytes regain parallel connections.
    func resplit(targetCount: Int) {
        let minChunk: Int64 = 4 * 1024 * 1024
        lock.lock()
        while true {
            let incomplete = entries.indices.filter {
                entries[$0].written < entries[$0].end - entries[$0].start + 1
            }
            guard incomplete.count < targetCount else { break }
            guard let largest = incomplete.max(by: { lhs, rhs in
                remainingLocked(entries[lhs]) < remainingLocked(entries[rhs])
            }), remainingLocked(entries[largest]) >= 2 * minChunk else { break }
            let entry = entries[largest]
            let head = entry.start + entry.written
            let mid = head + remainingLocked(entry) / 2
            entries[largest].end = mid - 1
            entries.append(Entry(start: mid, end: entry.end, written: 0))
        }
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries)
        lock.unlock()
        write(snapshot)
    }

    func flush() {
        lock.lock()
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries)
        lock.unlock()
        write(snapshot)
    }

    func saveNow() throws {
        lock.lock()
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries)
        lock.unlock()
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: sidecarURL, options: .atomic)
    }

    func deleteSidecar() {
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    private func remainingLocked(_ entry: Entry) -> Int64 {
        entry.end - entry.start + 1 - entry.written
    }

    private func write(_ snapshot: MapFile) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: sidecarURL, options: .atomic)
    }
}

private final class ConcurrentSegmentState: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    var firstError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func setError(_ error: Error) {
        lock.lock()
        if self.error == nil {
            self.error = error
        }
        lock.unlock()
    }
}
