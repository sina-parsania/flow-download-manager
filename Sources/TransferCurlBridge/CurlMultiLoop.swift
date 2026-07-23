// SPDX-License-Identifier: GPL-3.0-or-later

import CCurl
import Darwin
import Foundation

/// Concurrent ranged downloads via curl_multi (FR-TRN-009 foundation).
/// Dispatch-based SegmentedTransfer remains the default production path;
/// this loop is the multi-socket building block and is covered by integration tests.
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
        cookieJarPath: String? = nil
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

        try url.withCString { urlC in
            try withOptionalCString(userpwd) { userpwdC in
                try withOptionalCString(proxyURL) { proxyC in
                    try withOptionalCString(cookieJarPath) { cookieC in
                        for range in ranges {
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
                                    nil,
                                    nil,
                                    userpwdC,
                                    proxyC,
                                    cookieC
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

    private static func withOptionalCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) throws -> T
    ) throws -> T {
        guard let value else { return try body(nil) }
        return try value.withCString { try body($0) }
    }
}
