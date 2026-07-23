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
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) throws -> [Outcome] {
        guard !ranges.isEmpty else { throw MultiError.emptyRequests }
        try CurlBridge.initialize()

        let directory = partialURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = partialURL.path.withCString { path in
            open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard fd >= 0 else { throw MultiError.easyCreateFailed }
        defer { close(fd) }

        guard let multi = DMCurlMultiCreate() else {
            throw MultiError.multiInitFailed
        }
        var multiAlive = true
        defer {
            if multiAlive {
                DMCurlMultiCleanup(multi)
            }
        }

        // Owned downloads not yet finished. Cleared as each Finish runs.
        var liveDownloads: [OpaquePointer] = []
        defer {
            for download in liveDownloads {
                if let easy = DMCurlEasyDownloadGetHandle(download) {
                    _ = DMCurlMultiRemoveEasy(multi, easy)
                }
                var discarded = DMCurlDownloadResult()
                discarded.contentLength = -1
                DMCurlEasyDownloadFinish(download, CURLE_ABORTED_BY_CALLBACK, &discarded)
                DMCurlDownloadResultClear(&discarded)
            }
            liveDownloads.removeAll()
        }

        let connect = Int(connectTimeoutMilliseconds)
        let transfer = Int(transferTimeoutMilliseconds)
        let redirects = Int(maxRedirects)
        let progressState = onProgress.map { MultiProgressState(segmentCount: ranges.count, onProgress: $0) }
        // Retain per-segment boxes for the full multi loop lifetime.
        var progressBoxes: [MultiSegmentProgressBox] = []
        progressBoxes.reserveCapacity(ranges.count)

        try url.withCString { urlC in
            try withOptionalCString(userpwd) { userpwdC in
                try withOptionalCString(proxyURL) { proxyC in
                    try withOptionalCString(cookieJarPath) { cookieC in
                        try withOptionalCString(extraHeadersPayload) { headersC in
                            for (index, range) in ranges.enumerated() {
                                let progressBox: MultiSegmentProgressBox?
                                let progressCallback: DMCurlProgressCallback?
                                let progressUserdata: UnsafeMutableRawPointer?
                                if let progressState {
                                    let box = MultiSegmentProgressBox(
                                        segmentIndex: index,
                                        state: progressState
                                    )
                                    progressBoxes.append(box)
                                    progressBox = box
                                    progressCallback = { written, userdata in
                                        guard let userdata else { return 0 }
                                        let box = Unmanaged<MultiSegmentProgressBox>
                                            .fromOpaque(userdata)
                                            .takeUnretainedValue()
                                        box.record(written: Int64(written))
                                        return 0
                                    }
                                    progressUserdata = Unmanaged.passUnretained(box).toOpaque()
                                } else {
                                    progressBox = nil
                                    progressCallback = nil
                                    progressUserdata = nil
                                }
                                _ = progressBox
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
                                    throw MultiError.easyCreateFailed
                                }
                                let addCode = DMCurlMultiAddEasy(multi, easy)
                                guard addCode == CURLM_OK else {
                                    var discarded = DMCurlDownloadResult()
                                    discarded.contentLength = -1
                                    DMCurlEasyDownloadFinish(created, CURLE_FAILED_INIT, &discarded)
                                    DMCurlDownloadResultClear(&discarded)
                                    throw MultiError.multiAddFailed
                                }
                                liveDownloads.append(created)
                            }
                        }
                    }
                }
            }
        }
        // Keep boxes alive through perform/wait.
        try withExtendedLifetime(progressBoxes) {
            var running: Int32 = 0
            var performCode = DMCurlMultiPerform(multi, &running)
            guard performCode == CURLM_OK else {
                throw MultiError.curl(CURLE_FAILED_INIT)
            }

            while running > 0 {
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
            }
        }

        var codeByEasy: [UInt: CURLcode] = [:]
        var msgsLeft: Int32 = 0
        while true {
            guard let msg = DMCurlMultiInfoRead(multi, &msgsLeft) else { break }
            if msg.pointee.msg == CURLMSG_DONE, let easy = msg.pointee.easy_handle {
                codeByEasy[UInt(bitPattern: easy)] = msg.pointee.data.result
            }
        }

        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(liveDownloads.count)

        // Finish in creation order; take ownership out of liveDownloads first.
        let ordered = liveDownloads
        liveDownloads.removeAll(keepingCapacity: false)

        for (index, download) in ordered.enumerated() {
            let easy = DMCurlEasyDownloadGetHandle(download)
            let perform: CURLcode
            if let easy {
                perform = codeByEasy[UInt(bitPattern: easy)] ?? CURLE_OK
                _ = DMCurlMultiRemoveEasy(multi, easy)
            } else {
                perform = CURLE_FAILED_INIT
            }

            var result = DMCurlDownloadResult()
            result.contentLength = -1
            DMCurlEasyDownloadFinish(download, perform, &result)
            defer { DMCurlDownloadResultClear(&result) }

            if result.code == CURLE_ABORTED_BY_CALLBACK || (abortFlag?.pointee ?? 0) != 0 {
                // Finish remaining without leaving incomplete markers in liveDownloads.
                for leftover in ordered.suffix(from: index + 1) {
                    if let leftoverEasy = DMCurlEasyDownloadGetHandle(leftover) {
                        _ = DMCurlMultiRemoveEasy(multi, leftoverEasy)
                    }
                    var discarded = DMCurlDownloadResult()
                    discarded.contentLength = -1
                    DMCurlEasyDownloadFinish(leftover, CURLE_ABORTED_BY_CALLBACK, &discarded)
                    DMCurlDownloadResultClear(&discarded)
                }
                throw MultiError.aborted
            }
            guard result.code == CURLE_OK else {
                for leftover in ordered.suffix(from: index + 1) {
                    if let leftoverEasy = DMCurlEasyDownloadGetHandle(leftover) {
                        _ = DMCurlMultiRemoveEasy(multi, leftoverEasy)
                    }
                    var discarded = DMCurlDownloadResult()
                    discarded.contentLength = -1
                    DMCurlEasyDownloadFinish(leftover, CURLE_FAILED_INIT, &discarded)
                    DMCurlDownloadResultClear(&discarded)
                }
                throw MultiError.curl(result.code)
            }

            let status = Int(result.httpStatus)
            guard status == 206 || status == 200 else {
                for leftover in ordered.suffix(from: index + 1) {
                    if let leftoverEasy = DMCurlEasyDownloadGetHandle(leftover) {
                        _ = DMCurlMultiRemoveEasy(multi, leftoverEasy)
                    }
                    var discarded = DMCurlDownloadResult()
                    discarded.contentLength = -1
                    DMCurlEasyDownloadFinish(leftover, CURLE_OK, &discarded)
                    DMCurlDownloadResultClear(&discarded)
                }
                throw MultiError.httpStatus(status)
            }

            let wrote = Int64(result.bytesWritten)
            if let expected = ranges[index].expectedBytes, wrote != expected {
                for leftover in ordered.suffix(from: index + 1) {
                    if let leftoverEasy = DMCurlEasyDownloadGetHandle(leftover) {
                        _ = DMCurlMultiRemoveEasy(multi, leftoverEasy)
                    }
                    var discarded = DMCurlDownloadResult()
                    discarded.contentLength = -1
                    DMCurlEasyDownloadFinish(leftover, CURLE_OK, &discarded)
                    DMCurlDownloadResultClear(&discarded)
                }
                throw MultiError.incompleteWrite(expected: expected, wrote: wrote)
            }

            outcomes.append(
                Outcome(
                    httpStatus: status,
                    bytesWritten: wrote,
                    finalURL: result.finalURL.map { String(cString: $0) },
                    contentType: result.contentType.map { String(cString: $0) },
                    etag: result.etag.map { String(cString: $0) },
                    contentRange: result.contentRange.map { String(cString: $0) }
                )
            )
        }

        multiAlive = false
        DMCurlMultiCleanup(multi)
        return outcomes
    }

    private static func withExtendedLifetime(
        _ boxes: [MultiSegmentProgressBox],
        _ body: () throws -> Void
    ) throws {
        _ = boxes
        try body()
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
    private let onProgress: @Sendable (Int64) -> Void

    init(segmentCount: Int, onProgress: @escaping @Sendable (Int64) -> Void) {
        progressBySegment = Array(repeating: 0, count: segmentCount)
        self.onProgress = onProgress
    }

    func record(segment: Int, written: Int64) {
        lock.lock()
        if segment >= 0, segment < progressBySegment.count {
            progressBySegment[segment] = written
        }
        let total = progressBySegment.reduce(0, +)
        lock.unlock()
        onProgress(total)
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
