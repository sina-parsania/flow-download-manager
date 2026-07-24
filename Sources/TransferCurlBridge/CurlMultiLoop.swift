// SPDX-License-Identifier: GPL-3.0-or-later

import CCurl
import Darwin
import Foundation

/// Concurrent ranged downloads via curl_multi (FR-TRN-009).
/// SegmentedTransfer prefers this path when segmentCount > 1; Dispatch is the
/// recoverable fallback when multi setup fails.
public enum CurlMultiLoop {
    public struct RangeRequest: Sendable, Equatable {
        public let rangeHeader: String
        public let fileOffset: Int64
        public let expectedBytes: Int64?

        public init(rangeHeader: String, fileOffset: Int64, expectedBytes: Int64? = nil) {
            self.rangeHeader = rangeHeader
            self.fileOffset = fileOffset
            self.expectedBytes = expectedBytes
        }
    }

    public struct Outcome: Sendable, Equatable {
        public let httpStatus: Int
        public let bytesWritten: Int64
        public let finalURL: String?
        public let contentType: String?
        public let etag: String?
        public let contentRange: String?
        /// True when this easy was asked to stop because a replica already won
        /// the same byte range. A short `bytesWritten` is expected — not a failure.
        public let stoppedByRequest: Bool

        public init(
            httpStatus: Int,
            bytesWritten: Int64,
            finalURL: String?,
            contentType: String?,
            etag: String?,
            contentRange: String?,
            stoppedByRequest: Bool = false
        ) {
            self.httpStatus = httpStatus
            self.bytesWritten = bytesWritten
            self.finalURL = finalURL
            self.contentType = contentType
            self.etag = etag
            self.contentRange = contentRange
            self.stoppedByRequest = stoppedByRequest
        }
    }

    public enum MultiError: Error, Equatable, Sendable {
        case multiInitFailed
        case easyCreateFailed
        case multiAddFailed
        case curl(CURLcode)
        case httpStatus(Int)
        case incompleteWrite(expected: Int64, wrote: Int64)
        case aborted
        case emptyRequests
    }

    /// Downloads each range into the same open file (positioned writes) until all complete.
    /// When `onProgress` is set, per-segment write progress is summed and reported.
    ///
    /// `maxConcurrent` bounds how many easies are ever live in the multi handle at
    /// once (work-stealing / connection saturation, FR-TRN-009 S1). When `nil` or
    /// `>= ranges.count`, every range starts immediately (backward compatible).
    /// When lower, a pending queue refills a freed slot as soon as any easy
    /// finishes, so a fast connection immediately grabs the next range instead of
    /// idling until every live easy completes.
    public static func downloadRangesToFile(
        url: String,
        partialURL: URL,
        ranges: [RangeRequest],
        connectTimeoutMilliseconds: Int = 15000,
        transferTimeoutMilliseconds: Int = 0,
        maxRedirects: Int = 10,
        abortFlag: UnsafeMutablePointer<Int32>? = nil,
        userpwd: String? = nil,
        proxyURL: String? = nil,
        cookieJarPath: String? = nil,
        extraHeadersPayload: String? = nil,
        onProgress: (@Sendable (Int64) -> Void)? = nil,
        onSegmentProgress: (@Sendable (Int, Int64) -> Void)? = nil,
        maxConcurrent: Int? = nil,
        // Same group id ⇒ replicas of one ledger entry. When one finishes in
        // full, siblings in the group are asked to stop so the loser does not
        // download the whole chunk. `nil` means every range is its own group.
        replicaGroupByRangeIndex: [Int]? = nil
    ) throws -> [Outcome] {
        guard !ranges.isEmpty else { throw MultiError.emptyRequests }
        if let replicaGroupByRangeIndex {
            guard replicaGroupByRangeIndex.count == ranges.count else {
                throw MultiError.emptyRequests
            }
        }
        try CurlBridge.initialize()

        func groupID(for index: Int) -> Int {
            replicaGroupByRangeIndex?[index] ?? index
        }

        let directory = partialURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = partialURL.path.withCString { path in
            open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard fd >= 0 else { throw MultiError.easyCreateFailed }
        defer { close(fd) }

        // Prefer CPU over background work while the multi loop blocks this thread.
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)

        guard let multi = DMCurlMultiCreate() else {
            throw MultiError.multiInitFailed
        }
        var multiAlive = true
        defer {
            if multiAlive {
                DMCurlMultiCleanup(multi)
            }
        }

        // Owned downloads not yet finished (keyed by range index). Cleared as each
        // Finish runs; anything left here on scope exit (error/abort) is cleaned
        // up below.
        var liveByIndex: [Int: OpaquePointer] = [:]
        defer {
            for download in liveByIndex.values {
                if let easy = DMCurlEasyDownloadGetHandle(download) {
                    _ = DMCurlMultiRemoveEasy(multi, easy)
                }
                var discarded = DMCurlDownloadResult()
                discarded.contentLength = -1
                DMCurlEasyDownloadFinish(download, CURLE_ABORTED_BY_CALLBACK, &discarded)
                DMCurlDownloadResultClear(&discarded)
            }
            liveByIndex.removeAll()
        }

        let connect = Int(connectTimeoutMilliseconds)
        let transfer = Int(transferTimeoutMilliseconds)
        let redirects = Int(maxRedirects)
        let progressState: MultiProgressState? = (onProgress != nil || onSegmentProgress != nil)
            ? MultiProgressState(
                segmentCount: ranges.count,
                onProgress: onProgress,
                onSegmentProgress: onSegmentProgress
            )
            : nil

        let effectiveMax = max(1, min(maxConcurrent ?? ranges.count, ranges.count))
        var pending = Array(effectiveMax ..< ranges.count)
        var outcomesByIndex: [Outcome?] = Array(repeating: nil, count: ranges.count)
        // Retains a box only while its easy is live; freed right after that
        // easy is removed from the multi handle and finished.
        var boxesByIndex: [Int: MultiSegmentProgressBox] = [:]
        var easyIndexByPointer: [UInt: Int] = [:]
        // First range failure. Siblings keep running; thrown once they drain.
        var firstError: Error?

        try url.withCString { urlC in
            try withOptionalCString(userpwd) { userpwdC in
                try withOptionalCString(proxyURL) { proxyC in
                    try withOptionalCString(cookieJarPath) { cookieC in
                        try withOptionalCString(extraHeadersPayload) { headersC in
                            func startEasy(_ index: Int) throws {
                                let range = ranges[index]
                                let progressCallback: DMCurlProgressCallback?
                                let progressUserdata: UnsafeMutableRawPointer?
                                if let progressState {
                                    let box = MultiSegmentProgressBox(
                                        segmentIndex: index,
                                        state: progressState
                                    )
                                    boxesByIndex[index] = box
                                    progressCallback = { written, total, userdata in
                                        guard let userdata else { return 0 }
                                        let box = Unmanaged<MultiSegmentProgressBox>
                                            .fromOpaque(userdata)
                                            .takeUnretainedValue()
                                        // Segment progress is bytes within the range;
                                        // job-level total is supplied by SegmentedTransfer.
                                        _ = total
                                        box.record(written: Int64(written))
                                        return 0
                                    }
                                    progressUserdata = Unmanaged.passUnretained(box).toOpaque()
                                } else {
                                    progressCallback = nil
                                    progressUserdata = nil
                                }
                                let created: OpaquePointer? = range.rangeHeader.withCString { rangeC in
                                    DMCurlEasyDownloadCreate(
                                        urlC,
                                        fd,
                                        curl_off_t(range.fileOffset),
                                        rangeC,
                                        connect,
                                        transfer,
                                        redirects,
                                        abortFlag,
                                        progressCallback,
                                        progressUserdata,
                                        userpwdC,
                                        proxyC,
                                        cookieC,
                                        headersC
                                    )
                                }
                                guard let created,
                                      let easy = DMCurlEasyDownloadGetHandle(created)
                                else {
                                    boxesByIndex.removeValue(forKey: index)
                                    throw MultiError.easyCreateFailed
                                }
                                let addCode = DMCurlMultiAddEasy(multi, easy)
                                guard addCode == CURLM_OK else {
                                    var discarded = DMCurlDownloadResult()
                                    discarded.contentLength = -1
                                    DMCurlEasyDownloadFinish(created, CURLE_FAILED_INIT, &discarded)
                                    DMCurlDownloadResultClear(&discarded)
                                    boxesByIndex.removeValue(forKey: index)
                                    throw MultiError.multiAddFailed
                                }
                                liveByIndex[index] = created
                                easyIndexByPointer[UInt(bitPattern: easy)] = index
                            }

                            func finishEasy(index: Int, performCode: CURLcode) throws {
                                guard let download = liveByIndex.removeValue(forKey: index) else { return }
                                if let easy = DMCurlEasyDownloadGetHandle(download) {
                                    easyIndexByPointer.removeValue(forKey: UInt(bitPattern: easy))
                                    _ = DMCurlMultiRemoveEasy(multi, easy)
                                }

                                var result = DMCurlDownloadResult()
                                result.contentLength = -1
                                DMCurlEasyDownloadFinish(download, performCode, &result)
                                // Only now is the easy destroyed, so the progress box it
                                // points at (passUnretained) can safely be released.
                                boxesByIndex.removeValue(forKey: index)
                                defer { DMCurlDownloadResultClear(&result) }

                                if result.code == CURLE_ABORTED_BY_CALLBACK || (abortFlag?.pointee ?? 0) != 0 {
                                    throw MultiError.aborted
                                }
                                guard result.code == CURLE_OK else {
                                    throw MultiError.curl(result.code)
                                }

                                let wrote = Int64(result.bytesWritten)
                                let stopped = result.stoppedByRequest != 0
                                if stopped {
                                    // Hedge loser: short read is success. Do not
                                    // enforce expectedBytes and do not stop siblings.
                                    outcomesByIndex[index] = Outcome(
                                        httpStatus: Int(result.httpStatus),
                                        bytesWritten: wrote,
                                        finalURL: result.finalURL.map { String(cString: $0) },
                                        contentType: result.contentType.map { String(cString: $0) },
                                        etag: result.etag.map { String(cString: $0) },
                                        contentRange: result.contentRange.map { String(cString: $0) },
                                        stoppedByRequest: true
                                    )
                                    return
                                }

                                let status = Int(result.httpStatus)
                                guard status == 206 || status == 200 else {
                                    throw MultiError.httpStatus(status)
                                }
                                if let expected = ranges[index].expectedBytes, wrote != expected {
                                    throw MultiError.incompleteWrite(expected: expected, wrote: wrote)
                                }
                                outcomesByIndex[index] = Outcome(
                                    httpStatus: status,
                                    bytesWritten: wrote,
                                    finalURL: result.finalURL.map { String(cString: $0) },
                                    contentType: result.contentType.map { String(cString: $0) },
                                    etag: result.etag.map { String(cString: $0) },
                                    contentRange: result.contentRange.map { String(cString: $0) },
                                    stoppedByRequest: false
                                )

                                // A full winner asks every live replica of the same
                                // ledger entry to stop — they keep what they already
                                // wrote, but do not finish downloading the chunk.
                                let wonGroup = groupID(for: index)
                                for (liveIndex, liveDownload) in liveByIndex where groupID(for: liveIndex) == wonGroup {
                                    DMCurlEasyDownloadRequestStop(liveDownload)
                                }
                            }

                            /// Drains every `CURLMSG_DONE` available right now, then refills
                            /// each freed slot from `pending` so a fast connection grabs the
                            /// next range instead of idling until every live easy completes.
                            ///
                            /// Messages are collected before any handle is added or removed:
                            /// mutating the multi handle while iterating its own message
                            /// queue is not a contract libcurl documents.
                            ///
                            /// A range failure does not tear down healthy siblings. The first
                            /// error is recorded, refilling stops, and already-running easies
                            /// are drained to completion so their bytes stay recorded in the
                            /// caller's segment map — then the error is thrown.
                            @discardableResult
                            func drainCompletions() throws -> Int {
                                var completed: [(index: Int, code: CURLcode)] = []
                                var msgsLeft: Int32 = 0
                                while let msg = DMCurlMultiInfoRead(multi, &msgsLeft) {
                                    guard msg.pointee.msg == CURLMSG_DONE,
                                          let easy = msg.pointee.easy_handle,
                                          let index = easyIndexByPointer[UInt(bitPattern: easy)]
                                    else { continue }
                                    completed.append((index, msg.pointee.data.result))
                                }

                                for item in completed {
                                    do {
                                        try finishEasy(index: item.index, performCode: item.code)
                                    } catch {
                                        if firstError == nil { firstError = error }
                                    }
                                    // Keep refilling even after a failure. On a
                                    // lossy link the common case is one range
                                    // dropping while the rest are healthy;
                                    // draining the queue on the first error turns
                                    // a single blip into a stalled pass. The error
                                    // is still reported once everything settles.
                                    // Do not start new work after a job-wide abort.
                                    if firstError as? MultiError == .aborted { continue }
                                    guard let next = pending.first else { continue }
                                    pending.removeFirst()
                                    try startEasy(next)
                                }
                                return completed.count
                            }

                            for index in 0 ..< effectiveMax {
                                try startEasy(index)
                            }

                            var running: Int32 = 0
                            var performCode = DMCurlMultiPerform(multi, &running)
                            guard performCode == CURLM_OK else {
                                throw MultiError.curl(CURLE_FAILED_INIT)
                            }
                            try drainCompletions()

                            while !liveByIndex.isEmpty || !pending.isEmpty {
                                if let abortFlag, abortFlag.pointee != 0 {
                                    throw MultiError.aborted
                                }
                                var numfds: Int32 = 0
                                let waitCode = DMCurlMultiWait(multi, 250, &numfds)
                                guard waitCode == CURLM_OK else {
                                    throw MultiError.curl(CURLE_FAILED_INIT)
                                }
                                performCode = DMCurlMultiPerform(multi, &running)
                                guard performCode == CURLM_OK else {
                                    throw MultiError.curl(CURLE_FAILED_INIT)
                                }
                                let processed = try drainCompletions()
                                // libcurl reports nothing active and produced no
                                // completion, yet handles are still tracked: the
                                // easy↔index map has desynced. Fail instead of
                                // spinning on a wait that now returns instantly.
                                if running == 0, processed == 0, !liveByIndex.isEmpty {
                                    throw MultiError.curl(CURLE_FAILED_INIT)
                                }
                            }

                            if let firstError { throw firstError }
                        }
                    }
                }
            }
        }

        let outcomes = outcomesByIndex.compactMap(\.self)
        // Every range must report — winners with full bytes, stopped hedges with
        // a short read. Missing slots mean the multi map desynced.
        guard outcomes.count == ranges.count else {
            throw MultiError.curl(CURLE_FAILED_INIT)
        }
        // Each replica group needs at least one full (non-stopped) completion.
        // Otherwise a group of hedges could all stop each other and leave a hole.
        var fullGroups = Set<Int>()
        for (index, outcome) in outcomes.enumerated() where !outcome.stoppedByRequest {
            fullGroups.insert(groupID(for: index))
        }
        let allGroups = Set((0 ..< ranges.count).map(groupID(for:)))
        guard fullGroups == allGroups else {
            throw MultiError.curl(CURLE_FAILED_INIT)
        }

        multiAlive = false
        DMCurlMultiCleanup(multi)
        return outcomes
    }

    private static func withOptionalCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) throws -> T
    ) throws -> T {
        guard let value else { return try body(nil) }
        return try value.withCString { try body($0) }
    }
}

/// Aggregates per-segment curl write progress for a multi transfer.
private final class MultiProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var progressBySegment: [Int64]
    private let onProgress: (@Sendable (Int64) -> Void)?
    private let onSegmentProgress: (@Sendable (Int, Int64) -> Void)?

    init(
        segmentCount: Int,
        onProgress: (@Sendable (Int64) -> Void)?,
        onSegmentProgress: (@Sendable (Int, Int64) -> Void)?
    ) {
        progressBySegment = Array(repeating: 0, count: segmentCount)
        self.onProgress = onProgress
        self.onSegmentProgress = onSegmentProgress
    }

    func record(segment: Int, written: Int64) {
        lock.lock()
        if segment >= 0, segment < progressBySegment.count {
            progressBySegment[segment] = written
        }
        let total = progressBySegment.reduce(0, +)
        lock.unlock()
        onSegmentProgress?(segment, written)
        onProgress?(total)
    }
}

private final class MultiSegmentProgressBox {
    let segmentIndex: Int
    let state: MultiProgressState

    init(segmentIndex: Int, state: MultiProgressState) {
        self.segmentIndex = segmentIndex
        self.state = state
    }

    func record(written: Int64) {
        state.record(segment: segmentIndex, written: written)
    }
}
