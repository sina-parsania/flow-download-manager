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

    /// Adds duplicate work for the largest remaining chunks once slots go idle.
    ///
    /// At the tail `remaining.count` drops below the connection limit, so slots
    /// sit unused while the job waits on whichever connection is slowest. Racing
    /// a second connection over the same byte range costs nothing in concurrency
    /// — the slot was idle — and the slow connection is never killed, so it keeps
    /// contributing and may still win.
    ///
    /// Safe because a replica writes the *same bytes at the same offsets* of a
    /// resource whose identity the validator already pinned, so the duplicate
    /// `pwrite` is idempotent, and `SegmentLedger.record` keeps a monotonic
    /// `max()` per entry, so double reporting cannot inflate progress.
    ///
    /// The cost is bandwidth: without a cancel the loser downloads its chunk in
    /// full, so this is capped hard and only spends genuinely idle slots.
    static func hedged(
        _ remaining: [SegmentLedger.Work],
        connectionLimit: Int,
        maxHedges: Int = 2,
        minimumChunk: Int64 = 1024 * 1024
    ) -> [SegmentLedger.Work] {
        var idleSlots = connectionLimit - remaining.count
        guard idleSlots > 0, remaining.count > 1 else { return remaining }

        let candidates = remaining
            .filter { ($0.request.expectedBytes ?? 0) >= minimumChunk }
            .sorted { ($0.request.expectedBytes ?? 0) > ($1.request.expectedBytes ?? 0) }

        var work = remaining
        for candidate in candidates {
            guard idleSlots > 0, work.count - remaining.count < maxHedges else { break }
            work.append(candidate)
            idleSlots -= 1
        }
        return work
    }

    /// Backoff delay for a stalled pass, with full jitter.
    ///
    /// Jitter is the point, not the exponent. Without it, every segment that
    /// dropped on the same network blip retries at the same instant and
    /// recreates the burst that killed them. Full jitter — a uniform draw over
    /// the whole window rather than half of it — is the variant that spreads a
    /// synchronised herd best.
    static func backoffSeconds(
        stall: Int,
        base: Double = 0.5,
        cap: Double = 30,
        random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> Double {
        let exponent = min(max(stall, 1), 16)
        let window = min(cap, base * pow(2, Double(exponent - 1)))
        return random(0 ... max(window, 0))
    }

    /// Current size of `url`, or 0 when it does not exist.
    ///
    /// Deliberately not `URL.resourceValues(forKeys:)`: that bridges to `NSURL`,
    /// which caches per URL value. This function reads a partial's size, wipes the
    /// file when a resume is rejected, then reads the size again from the same
    /// `URL` — and the second read returned the stale pre-wipe size. Every wipe
    /// path therefore fell into the legacy contiguous-prefix branch and threw
    /// `incompleteWrite` instead of starting a clean download.
    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
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
        if RangeProbePolicy.shouldSkipProbe(url: url, options: options) {
            // An **expiring** signature is not a one-shot token: it can be fetched
            // repeatedly until it expires. Such URLs no longer forfeit parallelism
            // — the opening chunk answers the range question itself, for the same
            // one request a plain GET would have cost.
            //
            // Everything else keeps the conservative path. A credential-bearing
            // job (Cookie / Authorization / userpwd / cookie jar) may be a genuine
            // one-shot session download, and a signature with no expiry says
            // nothing either way — both get exactly one unranged GET, which is the
            // contract `OrchestratorIntegrationTests` pins.
            if !RangeProbePolicy.hasFragileCredentials(options),
               RangeProbePolicy.hasExplicitExpiry(url) {
                return try openingChunkOutcome(
                    url: url, partialURL: partialURL, options: options,
                    abortFlag: abortFlag, onProgress: onProgress,
                    useCurlMulti: useCurlMulti, hostMaxSegments: hostMaxSegments
                )
            }
            return try singleOutcome(
                url: url, partialURL: partialURL, options: options,
                abortFlag: abortFlag, onProgress: onProgress
            )
        }

        let sidecarURL = segmentMapURL(for: partialURL)

        // Segment-map resume: the authoritative record of downloaded ranges.
        if preferResume, let ledger = SegmentLedger.load(sidecarURL: sidecarURL) {
            let partialSize = fileSize(at: partialURL)
            if partialSize == ledger.total {
                // Probe live. A transient probe failure (network down at relaunch,
                // 5xx/429, etc.) MUST NOT discard the partial — propagate the error
                // so the job's retry/requeue path keeps the bytes on disk and
                // resumes later.
                let probe = try TransferCore.probeRangeSupport(url: url, options: options)
                // Length alone is not identity. A resource that changed but kept
                // its byte count would be resumed into, stitching old bytes to
                // new ones and yielding a right-sized corrupt file that passes
                // every later check. Compare the stored validator first.
                let verdict = (ledger.validator ?? ResourceValidator(
                    etag: nil, lastModified: nil, totalBytes: ledger.total
                )).compare(
                    probeETag: probe.etag,
                    probeLastModified: probe.lastModified,
                    probeTotalBytes: TransferCore.totalLength(from: probe)
                )
                if case let .changed(reason) = verdict {
                    // Discard rather than stitch. The bytes on disk belong to a
                    // version of this resource that no longer exists.
                    _ = reason
                    try? FileManager.default.removeItem(at: sidecarURL)
                    try? FileManager.default.removeItem(at: partialURL)
                } else if probe.httpStatus == 206 || probe.httpStatus == 200,
                          TransferCore.totalLength(from: probe) == ledger.total {
                    // Many hosts answer the Range: 0-0 probe with 200 while still
                    // honouring later ranged GETs for the map. Rejecting 200 here
                    // left a valid partial on disk and failed the job forever.
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
                // remote length is known and clearly different.
                else if let remoteTotal = TransferCore.totalLength(from: probe),
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

        let existing = fileSize(at: partialURL)

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

        let probe: TransferCore.ResourceIdentity
        do {
            probe = try TransferCore.probeRangeSupport(url: url, options: options)
        } catch let error as TransferCore.TransferError {
            switch error {
            // A 200 answer to the `Range: 0-0` probe is NOT proof the host refuses
            // ranges. CDNs routinely ignore Range on a cache MISS and honour it on
            // a HIT — measured on the same Cloudflare URL seconds apart. Treating
            // the miss as "no ranges" pinned that download to one connection for
            // its whole life, which on a high-RTT link is the difference between
            // ~1 MB/s and ~10 MB/s.
            //
            // Safe to attempt: `DMCurlRangeResponseIsValid` gates every segment on
            // 206 + an exact `Content-Range` match *before* the first `pwrite`, so
            // a host that genuinely ignores Range writes zero bytes and
            // `segmentedOrSingle` falls back cleanly.
            case .invalidRangeResponse(httpStatus: 200):
                guard let identity = try? TransferCore.probeForPartialRestart(
                    url: url, options: options
                ), let total = TransferCore.totalLength(from: identity) else {
                    return try singleOutcome(
                        url: url, partialURL: partialURL, options: options,
                        abortFlag: abortFlag, onProgress: onProgress
                    )
                }
                return try segmentedOrSingle(
                    url: url, partialURL: partialURL, sidecarURL: sidecarURL,
                    options: options, abortFlag: abortFlag, onProgress: onProgress,
                    probe: identity, total: total, useCurlMulti: useCurlMulti,
                    hostMaxSegments: hostMaxSegments
                )
            case .httpStatus, .invalidRangeResponse:
                return try singleOutcome(
                    url: url, partialURL: partialURL, options: options,
                    abortFlag: abortFlag, onProgress: onProgress
                )
            default:
                throw error
            }
        }
        guard probe.httpStatus == 206, let total = TransferCore.totalLength(from: probe) else {
            // Even without ranges, Content-Length from the probe lets Size/ETA
            // update before the first write callback learns dltotal.
            let knownTotal = TransferCore.totalLength(from: probe)
            let progress: TransferCore.ProgressHandler? = if let onProgress {
                { written, reported in onProgress(written, reported ?? knownTotal) }
            } else {
                nil
            }
            return try singleOutcome(
                url: url, partialURL: partialURL, options: options,
                abortFlag: abortFlag, onProgress: progress
            )
        }

        return try segmentedOrSingle(
            url: url, partialURL: partialURL, sidecarURL: sidecarURL,
            options: options, abortFlag: abortFlag, onProgress: onProgress,
            probe: probe, total: total, useCurlMulti: useCurlMulti,
            hostMaxSegments: hostMaxSegments
        )
    }

    /// Tiles `total` and runs the map loop, falling back to a single stream when
    /// the host turns out not to honour ranges after all.
    ///
    /// The fallback only fires when the ledger recorded **zero** bytes, i.e. every
    /// segment was rejected by the `Content-Range` gate before writing anything.
    /// A pass that moved bytes propagates its error instead, so the job's normal
    /// retry path keeps what is already on disk — a partial is never wiped on the
    /// strength of one bad response.
    private static func segmentedOrSingle(
        url: String,
        partialURL: URL,
        sidecarURL: URL,
        options: TransferCore.DownloadOptions,
        abortFlag: TransferAbortFlag?,
        onProgress: TransferCore.ProgressHandler?,
        probe: TransferCore.ResourceIdentity,
        total: Int64,
        useCurlMulti: Bool,
        hostMaxSegments: Int?
    ) throws -> Outcome {
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
            sidecarURL: sidecarURL,
            // Bind the map to what the server said this resource is right now, so
            // a later resume can tell "same file" from "same size".
            validator: ResourceValidator(
                etag: probe.etag,
                lastModified: probe.lastModified,
                totalBytes: total
            )
        )
        // Save the map before preallocating: once the file is truncated to
        // `total`, only the map can say what is really on disk.
        try ledger.saveNow()
        try preallocate(partialURL: partialURL, size: total)

        do {
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
                hostMaxSegments: hostMaxSegments,
                // The catch below is the fallback that makes bailing early safe.
                bailOnInvalidRange: true
            )
        } catch TransferCore.TransferError.invalidRangeResponse where ledger.downloadedBytes() == 0 {
            // The host does not honour ranges on the real GETs either. Nothing was
            // written, so clearing the preallocated shell and its map is safe —
            // and required, or the next run would resume into an empty full-size
            // file whose segment map claims ranges that never arrived.
            try? FileManager.default.removeItem(at: sidecarURL)
            try? FileManager.default.removeItem(at: partialURL)
            return try singleOutcome(
                url: url, partialURL: partialURL, options: options,
                abortFlag: abortFlag, onProgress: onProgress
            )
        }
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
            sidecarURL: segmentMapURL(for: partialURL),
            validator: ResourceValidator(
                etag: probe.etag,
                lastModified: probe.lastModified,
                totalBytes: total
            )
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
        hostMaxSegments: Int? = nil,
        // Only the fresh-download paths set this: they can fall back to a single
        // stream, so a rejected `Content-Range` is worth returning at once.
        bailOnInvalidRange: Bool = false
    ) throws -> Outcome {
        // Publish already-downloaded bytes immediately so relaunch UI does not
        // flash 0% before the first curl progress callback.
        onProgress?(ledger.baseOffset + ledger.downloadedBytes(), ledger.total)
        // ONE governor for the whole job, fed the ledger's aggregate byte count.
        // The per-easy governor inside `downloadSingleStream` cannot cap a
        // segmented transfer: the curl_multi transport never goes through it at
        // all, and the Dispatch fallback would build one bucket per segment,
        // each allowed the full rate. Segment options below have the cap
        // stripped so this is the only thing throttling.
        let governor: SyncBandwidthGovernor? = options.maxBytesPerSecond > 0
            ? SyncBandwidthGovernor(bytesPerSecond: options.maxBytesPerSecond)
            : nil
        // Same reasoning for the shared limiter: one meter for the whole job, fed
        // the ledger's aggregate count, so the job contributes to the global and
        // per-host queues exactly once per byte rather than once per segment.
        let sharedMeter: RateLimitedProgressMeter? = {
            guard let limiter = options.rateLimiter,
                  limiter.isLimited(host: options.rateLimitHost)
            else { return nil }
            return RateLimitedProgressMeter(limiter: limiter, host: options.rateLimitHost)
        }()
        var segmentOptions = options
        segmentOptions.maxBytesPerSecond = 0
        // Segments must not charge the shared queues individually — the job-level
        // meter above already accounts for every byte, and double-charging would
        // throttle to a fraction of the configured rate.
        segmentOptions.rateLimiter = nil
        // Budget is spent on *stalls*, not on errors. A pass that moved bytes
        // proves the link works, however many individual ranges hiccuped, so it
        // resets the counter. The old rule — 3 failures for the entire job —
        // made a multi-gigabyte download on a lossy link impossible: three blips
        // over an hour and the whole thing failed permanently.
        let maxConsecutiveStalls = 10
        var consecutiveStalls = 0
        // Host-clamped connection cap for the live multi loop. Chunk count in
        // the ledger may be finer (S1 tiling); this only bounds concurrency.
        // Start at the ceiling, back off on trouble, recover on success.
        //
        // NOT classic AIMD-from-below: a healthy download is a *single* pass, so
        // anything that ramps up between passes never ramps at all — it would
        // just cap every clean transfer at the starting value. Additive increase
        // only earns its keep on a link that stalled and is recovering, which is
        // exactly when multiple passes happen.
        let ceiling = maxConcurrent
        var connectionLimit = maxConcurrent
        while true {
            if abortFlag?.isSet == true {
                ledger.flush()
                throw TransferCore.TransferError.aborted
            }
            let remaining = ledger.remainingWork()
            if remaining.isEmpty { break }
            let work = hedged(remaining, connectionLimit: connectionLimit)
            let entryIndices = work.map(\.entryIndex)
            let bases = work.map(\.baseWritten)
            let progressOffset = ledger.baseOffset
            let bytesBeforePass = ledger.downloadedBytes()
            do {
                try runSegmentedRanges(
                    url: url,
                    partialURL: partialURL,
                    ranges: work.map(\.request),
                    options: segmentOptions,
                    abortFlag: abortFlag,
                    useCurlMulti: useCurlMulti,
                    maxConcurrent: connectionLimit,
                    // Same ledger entry ⇒ same group. CurlMultiLoop stops losers
                    // when one replica finishes the range in full.
                    replicaGroupByRangeIndex: entryIndices,
                    onSegmentProgress: { segment, written in
                        guard segment >= 0, segment < entryIndices.count else { return }
                        let done = ledger.record(
                            entry: entryIndices[segment],
                            written: bases[segment] + written
                        )
                        onProgress?(progressOffset + done, ledger.total)
                        // `done` is the job's cumulative total, so one governor
                        // sees the aggregate rate across every live segment.
                        // On the curl_multi transport this callback runs on the
                        // single multi thread, so sleeping here throttles all
                        // segments at once — which is exactly the intent.
                        governor?.noteProgress(totalWritten: done)
                        sharedMeter?.noteProgress(totalWritten: done)
                    }
                )
                // Unique entries only — hedges share an entryIndex.
                ledger.markCompleted(entryIndices: Array(Set(entryIndices)))
                // Additive increase, for a link recovering from a stall: each
                // clean pass earns one connection back, up to the ceiling it
                // started from. On a healthy link there is only one pass and this
                // never fires, which is correct — it was never throttled.
                consecutiveStalls = 0
                connectionLimit = min(connectionLimit + 1, ceiling)
            } catch {
                ledger.flush()
                if abortFlag?.isSet == true { throw TransferCore.TransferError.aborted }
                if case TransferCore.TransferError.aborted = error { throw error }
                // Hand a rejected `Content-Range` straight back when — and only
                // when — the caller has a single-stream fallback waiting. Ten
                // passes with backoff up to 30 s each is minutes of nothing before
                // a fallback that would have worked immediately.
                //
                // NOT unconditional: this is exactly the CDN whose answer flips
                // between 200 on a cache miss and 206 on a hit, so retrying really
                // can change it. On the resume paths there is no fallback, the
                // throw reaches `handleFailure`, and that spends one of only
                // `RetryPolicy.maxAttempts` (8) whole-job attempts — so those keep
                // the backoff passes that let a later hit succeed.
                if bailOnInvalidRange,
                   case TransferCore.TransferError.invalidRangeResponse = error { throw error }

                if ledger.downloadedBytes() > bytesBeforePass {
                    consecutiveStalls = 0
                } else {
                    consecutiveStalls += 1
                }
                guard consecutiveStalls < maxConsecutiveStalls else { throw error }

                // Multiplicative decrease. Errors on a congested path mean the
                // link cannot carry this many connections; adding more makes it
                // worse. Floor of 2 so a rough patch cannot collapse the job to
                // single-stream and leave it there.
                connectionLimit = max(2, min(connectionLimit / 2, ceiling))
                ledger.resplit(targetCount: connectionLimit)
                Thread.sleep(forTimeInterval: backoffSeconds(stall: consecutiveStalls))
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
        replicaGroupByRangeIndex: [Int]? = nil,
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
                    maxConcurrent: maxConcurrent,
                    replicaGroupByRangeIndex: replicaGroupByRangeIndex
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
                        { written, _ in report(index, written) }
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

    /// Opening chunk size for a URL that must not be probed separately. Small
    /// enough that a range-honouring host loses almost no serial prefix before
    /// parallelism starts, and it only ever has to fit *below* the ledger's 4 MiB
    /// minimum tile, never inside one.
    private static let openingChunkBytes: Int64 = 1024 * 1024

    /// Filters the opening chunk's reported total before it reaches the UI.
    ///
    /// On a 206 libcurl reports the *slice* length as `dltotal`, so the window
    /// would read "… / 1 MiB" until the map loop corrects it a moment later. Only
    /// a 200 reports something larger, and in that case it really is the file
    /// size. Anything else is withheld, which leaves the UI's existing total
    /// untouched rather than replacing it with a wrong one.
    private static func openingProgress(
        _ onProgress: TransferCore.ProgressHandler?
    ) -> TransferCore.ProgressHandler? {
        guard let onProgress else { return nil }
        let slice = openingChunkBytes
        return { written, reported in
            guard let reported, reported > slice else {
                onProgress(written, nil)
                return
            }
            onProgress(written, reported)
        }
    }

    /// First request doubles as the range probe, for URLs where a throwaway probe
    /// could burn a one-shot token.
    ///
    /// Asks for `bytes=0-N` with `allowFullBodyOn200`, so exactly one request is
    /// spent and its bytes are kept no matter how the host answers:
    ///
    /// - **206** — ranges work and `Content-Range` carries the total. The prefix is
    ///   already on disk, so the remainder is tiled and run in parallel.
    /// - **200** — the host ignored Range and sent the whole body, which was
    ///   written from offset 0. That *is* the finished single-stream download.
    /// - **anything else** — nothing was written and the token was not consumed
    ///   (`/fixtures/once` answers a ranged GET with 403 without burning it), so a
    ///   plain GET still succeeds.
    ///
    /// Before this, such URLs returned `singleOutcome` unconditionally: an
    /// expiring CDN signature (`?…&expires=…&sig=…`) is not a one-shot token, and
    /// pinning every one of them to a single connection is what capped those
    /// downloads at one connection's worth of throughput.
    private static func openingChunkOutcome(
        url: String,
        partialURL: URL,
        options: TransferCore.DownloadOptions,
        abortFlag: TransferAbortFlag?,
        onProgress: TransferCore.ProgressHandler?,
        useCurlMulti: Bool,
        hostMaxSegments: Int?
    ) throws -> Outcome {
        // This path has always restarted from zero (`singleOutcome` opens with
        // O_TRUNC). A ranged open does not truncate, so clear the partial
        // explicitly rather than write a new body over a stale tail.
        try? FileManager.default.removeItem(at: partialURL)
        try? FileManager.default.removeItem(at: segmentMapURL(for: partialURL))

        let opening: TransferCore.TransferOutcome
        do {
            opening = try TransferCore.downloadSingleStream(
                url: url,
                partialURL: partialURL,
                rangeHeader: "0-\(openingChunkBytes - 1)",
                fileOffset: 0,
                options: options,
                abortFlag: abortFlag,
                onProgress: openingProgress(onProgress),
                allowFullBodyOn200: true
            )
        } catch let error as TransferCore.TransferError {
            switch error {
            case .httpStatus, .invalidRangeResponse:
                // Host refused the ranged form without serving it. Nothing was
                // written and no token was spent — a plain GET is still good.
                return try singleOutcome(
                    url: url, partialURL: partialURL, options: options,
                    abortFlag: abortFlag, onProgress: onProgress
                )
            default:
                throw error
            }
        }

        let prefix = opening.bytesWritten
        // ONLY completion may short-circuit here. Folding "the remainder is too
        // small to split" into this guard reported a 1.5 MiB file as finished
        // after 1 MiB: the remainder tiles to one connection, which is a valid
        // answer to "how many connections", not a reason to stop downloading.
        guard opening.identity.httpStatus == 206,
              let total = TransferCore.totalLength(from: opening.identity),
              prefix > 0, prefix < total
        else {
            // 200 — the whole body was already written — or a 206 that finished
            // the file outright.
            try synchronizeFile(at: partialURL)
            return Outcome(
                identity: opening.identity,
                bytesWritten: prefix,
                segmentCount: 1,
                partialURL: partialURL
            )
        }

        // Same shape as a legacy contiguous-prefix resume: the bytes on disk are
        // the base, and only `[prefix, total)` gets tiled. A single-connection
        // remainder still goes through the map loop, so its completion is checked
        // against `ledger.total` like any other.
        let connectionCount = max(1, preferredSegmentCount(
            totalBytes: total - prefix, hostMaxSegments: hostMaxSegments
        ))
        let ledger = SegmentLedger(
            total: total,
            baseOffset: prefix,
            entries: tile(from: prefix, total: total, count: chunkCount(
                from: prefix, total: total, connectionCount: connectionCount
            )),
            sidecarURL: segmentMapURL(for: partialURL),
            validator: ResourceValidator(
                etag: opening.identity.etag,
                lastModified: opening.identity.lastModified,
                totalBytes: total
            )
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
            probe: opening.identity,
            useCurlMulti: useCurlMulti,
            maxConcurrent: connectionCount,
            hostMaxSegments: hostMaxSegments
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
        /// Absent in maps written before validators existed. Decoding must keep
        /// working for those — a missing validator means "cannot verify", which
        /// still resumes; only a contradicted one rejects.
        var validator: ResourceValidator?
    }

    let total: Int64
    /// Bytes on disk before the mapped region (legacy contiguous-prefix resume).
    let baseOffset: Int64
    /// What the server said this resource was when the map was created.
    let validator: ResourceValidator?

    private let sidecarURL: URL
    private let lock = NSLock()
    private var entries: [Entry]
    private var lastSaveNanos: UInt64 = 0

    init(
        total: Int64,
        baseOffset: Int64,
        entries: [Entry],
        sidecarURL: URL,
        validator: ResourceValidator? = nil
    ) {
        self.total = total
        self.baseOffset = baseOffset
        self.entries = entries
        self.sidecarURL = sidecarURL
        self.validator = validator
    }

    static func load(sidecarURL: URL) -> SegmentLedger? {
        guard let data = try? Data(contentsOf: sidecarURL),
              let file = try? JSONDecoder().decode(MapFile.self, from: data),
              file.total > 0,
              !file.entries.isEmpty,
              file.entries.allSatisfy({ entry in
                  entry.start >= 0 && entry.end < file.total && entry.start <= entry.end
                      && entry.written >= 0 && entry.written <= entry.end - entry.start + 1
              }),
              isStructurallyValid(file)
        else { return nil }
        return SegmentLedger(
            total: file.total,
            baseOffset: file.baseOffset,
            entries: file.entries,
            sidecarURL: sidecarURL,
            validator: file.validator
        )
    }

    /// Contiguous coverage from `baseOffset` through `total - 1`, sorted, no gaps
    /// or overlaps. Invalid maps return nil from `load` without rewriting the sidecar.
    private static func isStructurallyValid(_ file: MapFile) -> Bool {
        guard file.baseOffset >= 0, file.baseOffset < file.total else { return false }
        let entries = file.entries
        guard let first = entries.first, let last = entries.last else { return false }
        guard first.start == file.baseOffset else { return false }
        guard last.end == file.total - 1 else { return false }

        for index in entries.indices {
            let entry = entries[index]
            if index > 0 {
                let previous = entries[index - 1]
                guard previous.start < entry.start else { return false }
                guard previous.end < Int64.max else { return false }
                guard entry.start == previous.end + 1 else { return false }
            }
        }
        return true
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    struct Work: Equatable {
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
            snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
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
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
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
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
        lock.unlock()
        write(snapshot)
    }

    func flush() {
        lock.lock()
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
        lock.unlock()
        write(snapshot)
    }

    func saveNow() throws {
        lock.lock()
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
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
