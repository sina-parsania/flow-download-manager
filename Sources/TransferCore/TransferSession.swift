// SPDX-License-Identifier: GPL-3.0-or-later

import CCurl
import Darwin
import Foundation
import TransferCurlBridge

/// Single-stream and ranged transfer orchestration over the pinned libcurl stack
/// (FR-TRN-001…009 foundation). Multi-socket adaptive segmentation builds on this.
public enum TransferCore {
    public struct HTTPHeader: Sendable, Equatable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public struct DownloadOptions: Sendable, Equatable {
        /// 8 s, not 15: on a high-RTT or lossy path a second attempt through the
        /// retry loop beats one long wait, and a dead slot held for 15 s is a
        /// connection not carrying bytes.
        public var connectTimeoutMilliseconds: Int
        public var transferTimeoutMilliseconds: Int
        public var maxRedirects: Int
        /// HTTP basic/digest credentials as `user:password`. Never log this value.
        public var userpwd: String?
        /// Proxy URL such as `http://host:8080` or `socks5://host:1080`.
        public var proxyURL: String?
        /// Netscape cookie jar path for CURLOPT_COOKIEFILE / CURLOPT_COOKIEJAR.
        public var cookieJarPath: String?
        /// Validated custom request headers (FR-TRN-005).
        public var extraHeaders: [HTTPHeader]
        /// Soft cap in bytes/second for THIS transfer alone; `0` means unlimited
        /// (FR-TRN-011). Global and per-host ceilings are enforced separately by
        /// ``rateLimiter`` — they cannot live here, because a value copied into
        /// each transfer's options is by construction a per-transfer cap.
        public var maxBytesPerSecond: Int64
        /// Process-wide limiter enforcing the global and per-host ceilings across
        /// every concurrent transfer. `nil` when neither ceiling is configured.
        ///
        /// Not part of `Equatable`: it is a shared reference, and two option sets
        /// describing the same transfer should compare equal regardless of which
        /// limiter instance they were handed.
        public var rateLimiter: SharedRateLimiter?
        /// Host these bytes are charged to in ``rateLimiter``. Resolved once by
        /// the caller rather than re-parsed from the URL on every progress tick.
        public var rateLimitHost: String?

        public init(
            connectTimeoutMilliseconds: Int = 8000,
            transferTimeoutMilliseconds: Int = 0,
            maxRedirects: Int = 10,
            userpwd: String? = nil,
            proxyURL: String? = nil,
            cookieJarPath: String? = nil,
            extraHeaders: [HTTPHeader] = [],
            maxBytesPerSecond: Int64 = 0,
            rateLimiter: SharedRateLimiter? = nil,
            rateLimitHost: String? = nil
        ) {
            self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
            self.transferTimeoutMilliseconds = transferTimeoutMilliseconds
            self.maxRedirects = maxRedirects
            self.userpwd = userpwd
            self.proxyURL = proxyURL
            self.cookieJarPath = cookieJarPath
            self.extraHeaders = extraHeaders
            self.maxBytesPerSecond = maxBytesPerSecond
            self.rateLimiter = rateLimiter
            self.rateLimitHost = rateLimitHost
        }

        /// Excludes ``rateLimiter``: it is shared mutable infrastructure, not part
        /// of what makes two option sets describe the same transfer.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.connectTimeoutMilliseconds == rhs.connectTimeoutMilliseconds
                && lhs.transferTimeoutMilliseconds == rhs.transferTimeoutMilliseconds
                && lhs.maxRedirects == rhs.maxRedirects
                && lhs.userpwd == rhs.userpwd
                && lhs.proxyURL == rhs.proxyURL
                && lhs.cookieJarPath == rhs.cookieJarPath
                && lhs.extraHeaders == rhs.extraHeaders
                && lhs.maxBytesPerSecond == rhs.maxBytesPerSecond
                && lhs.rateLimitHost == rhs.rateLimitHost
        }

        /// Newline-separated `Name: Value` lines for CURLOPT_HTTPHEADER.
        public var extraHeadersCurlPayload: String? {
            guard !extraHeaders.isEmpty else { return nil }
            return extraHeaders.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        }
    }

    public struct ResourceIdentity: Sendable, Equatable {
        public let finalURL: String
        public let contentLength: Int64?
        public let contentType: String?
        public let etag: String?
        public let lastModified: String?
        public let acceptRanges: String?
        public let contentDisposition: String?
        public let contentRange: String?
        public let httpStatus: Int

        public var advertisesByteRanges: Bool {
            (acceptRanges ?? "").lowercased().contains("bytes")
        }
    }

    public struct TransferOutcome: Sendable, Equatable {
        public let identity: ResourceIdentity
        public let bytesWritten: Int64
        public let partialURL: URL
    }

    public enum TransferError: Error, Equatable, Sendable {
        case curl(CURLcode)
        case httpStatus(Int)
        case invalidRangeResponse(httpStatus: Int)
        case emptyURL
        case fileOpenFailed
        case incompleteWrite(expected: Int64?, wrote: Int64)
        case unsupportedScheme(String)
        case aborted
    }

    public typealias ProgressHandler = @Sendable (_ bytesTransferred: Int64, _ totalBytes: Int64?) -> Void

    /// Downloads `url` into a sibling partial file at `partialURL` using positioned writes.
    public static func downloadSingleStream(
        url: String,
        partialURL: URL,
        rangeHeader: String? = nil,
        fileOffset: Int64 = 0,
        options: DownloadOptions = DownloadOptions(),
        abortFlag: TransferAbortFlag? = nil,
        onProgress: ProgressHandler? = nil,
        allowFullBodyOn200: Bool = false
    ) throws -> TransferOutcome {
        try downloadSingleStream(
            url: url,
            partialURL: partialURL,
            rangeHeader: rangeHeader,
            fileOffset: fileOffset,
            options: options,
            abortFlag: abortFlag,
            onProgress: onProgress,
            bodyByteLimit: 0,
            allowFullBodyOn200: allowFullBodyOn200
        )
    }

    private static func downloadSingleStream(
        url: String,
        partialURL: URL,
        rangeHeader: String? = nil,
        fileOffset: Int64 = 0,
        options: DownloadOptions = DownloadOptions(),
        abortFlag: TransferAbortFlag? = nil,
        onProgress: ProgressHandler? = nil,
        bodyByteLimit: Int64 = 0,
        allowFullBodyOn200: Bool = false
    ) throws -> TransferOutcome {
        try CurlBridge.initialize()

        let parsed = try CurlURLParser.parse(url)
        guard parsed.isPhase1Supported else {
            throw TransferError.unsupportedScheme(parsed.scheme)
        }

        let directory = partialURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let openFlags = rangeHeader == nil ? O_CREAT | O_RDWR | O_TRUNC : O_CREAT | O_RDWR
        let fd = partialURL.path.withCString { path in
            open(path, openFlags, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard fd >= 0 else { throw TransferError.fileOpenFailed }
        defer { close(fd) }

        var result = DMCurlDownloadResult()
        result.contentLength = -1
        defer { DMCurlDownloadResultClear(&result) }

        let code = performDownload(
            url: url,
            fd: fd,
            fileOffset: fileOffset,
            rangeHeader: rangeHeader,
            options: options,
            abortFlag: abortFlag,
            onProgress: onProgress,
            bodyByteLimit: bodyByteLimit,
            allowFullBodyOn200: allowFullBodyOn200,
            result: &result
        )

        if result.rangeResponseInvalid != 0 {
            throw TransferError.invalidRangeResponse(httpStatus: Int(result.httpStatus))
        }
        if code == CURLE_ABORTED_BY_CALLBACK || abortFlag?.isSet == true {
            throw TransferError.aborted
        }
        guard code == CURLE_OK else {
            throw TransferError.curl(code)
        }

        let status = Int(result.httpStatus)
        if parsed.isHTTPFamily {
            let successStatuses: Set<Int> = rangeHeader == nil ? [200] : [206]
            guard successStatuses.contains(status) else {
                throw TransferError.httpStatus(status)
            }
        } else {
            // FTP reports 226/250 on a completed transfer and SFTP reports 0.
            // Applying the HTTP gate here made every non-HTTP link fail. curl
            // already surfaced real failures as a non-OK CURLcode above, so a
            // 2xx-or-zero response code is success for these schemes.
            guard status == 0 || (200 ... 299).contains(status) else {
                throw TransferError.httpStatus(status)
            }
        }

        let contentLength: Int64? = result.contentLength >= 0 ? Int64(result.contentLength) : nil
        if rangeHeader == nil, bodyByteLimit == 0, let contentLength, result.bytesWritten != contentLength {
            throw TransferError.incompleteWrite(expected: contentLength, wrote: Int64(result.bytesWritten))
        }

        let identity = ResourceIdentity(
            finalURL: result.finalURL.map { String(cString: $0) } ?? url,
            contentLength: contentLength,
            contentType: result.contentType.map { String(cString: $0) },
            etag: result.etag.map { String(cString: $0) },
            lastModified: result.lastModified.map { String(cString: $0) },
            acceptRanges: result.acceptRanges.map { String(cString: $0) },
            contentDisposition: result.contentDisposition.map { String(cString: $0) },
            contentRange: result.contentRange.map { String(cString: $0) },
            httpStatus: status
        )

        return TransferOutcome(
            identity: identity,
            bytesWritten: Int64(result.bytesWritten),
            partialURL: partialURL
        )
    }

    /// Resume an existing partial when the server supports ranges; otherwise
    /// restart via a sibling replacement partial so the original survives failure.
    public static func resumeOrDownload(
        url: String,
        partialURL: URL,
        options: DownloadOptions = DownloadOptions(),
        abortFlag: TransferAbortFlag? = nil,
        onProgress: ProgressHandler? = nil
    ) throws -> TransferOutcome {
        let existing = partialFileSize(at: partialURL)
        guard existing > 0 else {
            return try downloadSingleStream(
                url: url,
                partialURL: partialURL,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress
            )
        }

        let probe = try probeForPartialRestart(url: url, options: options)
        switch PartialRestartPolicy.classify(existingBytes: existing, probe: probe) {
        case .freshDownload:
            return try downloadSingleStream(
                url: url,
                partialURL: partialURL,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress
            )
        case let .resumeFromOffset(existing, total):
            return try resumeFromOffset(
                url: url,
                partialURL: partialURL,
                existing: existing,
                total: total,
                probe: probe,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress
            )
        case let .restartViaReplacement(_, total):
            return try restartViaReplacement(
                url: url,
                partialURL: partialURL,
                total: total,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress
            )
        case let .ambiguousPreallocatedShell(total):
            throw TransferError.incompleteWrite(expected: total, wrote: existing)
        case let .unknownRemoteTotal(existing):
            throw TransferError.incompleteWrite(expected: nil, wrote: existing)
        }
    }

    private static func partialFileSize(at partialURL: URL) -> Int64 {
        // Uncached on purpose — see SegmentedTransfer.fileSize(at:). A cached
        // NSURL size read after a wipe reports the pre-wipe bytes.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    private static func resumeFromOffset(
        url: String,
        partialURL: URL,
        existing: Int64,
        total: Int64,
        probe: ResourceIdentity,
        options: DownloadOptions,
        abortFlag: TransferAbortFlag?,
        onProgress: ProgressHandler?
    ) throws -> TransferOutcome {
        let progress: ProgressHandler? = if let onProgress {
            { written, reported in onProgress(existing + written, reported.map { existing + $0 } ?? total) }
        } else {
            nil
        }
        let resumed = try downloadSingleStream(
            url: url,
            partialURL: partialURL,
            rangeHeader: "\(existing)-\(total - 1)",
            fileOffset: existing,
            options: options,
            abortFlag: abortFlag,
            onProgress: progress
        )
        let size = partialFileSize(at: partialURL)
        let expectedAppend = total - existing
        guard size == total, resumed.bytesWritten == expectedAppend else {
            throw TransferError.incompleteWrite(expected: total, wrote: size)
        }
        return TransferOutcome(
            identity: ResourceIdentity(
                finalURL: resumed.identity.finalURL,
                contentLength: total,
                contentType: resumed.identity.contentType ?? probe.contentType,
                etag: resumed.identity.etag ?? probe.etag,
                lastModified: resumed.identity.lastModified ?? probe.lastModified,
                acceptRanges: probe.acceptRanges,
                contentDisposition: resumed.identity.contentDisposition ?? probe.contentDisposition,
                contentRange: resumed.identity.contentRange,
                httpStatus: resumed.identity.httpStatus
            ),
            bytesWritten: size,
            partialURL: partialURL
        )
    }

    /// Downloads the full object into a unique sibling partial, then atomically
    /// replaces the original only after length verification and fsync succeed.
    private static func restartViaReplacement(
        url: String,
        partialURL: URL,
        total: Int64,
        options: DownloadOptions,
        abortFlag: TransferAbortFlag?,
        onProgress: ProgressHandler?
    ) throws -> TransferOutcome {
        let replacementURL = partialURL
            .deletingLastPathComponent()
            .appendingPathComponent(".repl-\(UUID().uuidString)-\(partialURL.lastPathComponent)")

        do {
            let downloaded = try downloadSingleStream(
                url: url,
                partialURL: replacementURL,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress
            )
            guard downloaded.bytesWritten == total else {
                throw TransferError.incompleteWrite(expected: total, wrote: downloaded.bytesWritten)
            }
            try synchronizePartial(at: replacementURL)
            _ = try FileManager.default.replaceItem(
                at: partialURL,
                withItemAt: replacementURL,
                backupItemName: nil,
                options: [],
                resultingItemURL: nil
            )
            return TransferOutcome(
                identity: downloaded.identity,
                bytesWritten: total,
                partialURL: partialURL
            )
        } catch {
            try? FileManager.default.removeItem(at: replacementURL)
            throw error
        }
    }

    private static func synchronizePartial(at url: URL) throws {
        let fd = url.path.withCString { path in
            open(path, O_WRONLY)
        }
        guard fd >= 0 else { throw TransferError.fileOpenFailed }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw TransferError.fileOpenFailed
        }
    }

    /// Identity for a host that answered the `Range: 0-0` probe with HTTP 200.
    /// Falls back to a plain capped GET, so the caller still learns the total even
    /// though the ranged probe threw. Used when classifying an existing partial for
    /// resume vs restart, and by ``SegmentedTransfer`` to recover a tiling target
    /// on CDNs that ignore Range on a cache miss.
    ///
    /// Never weakens ranged-byte validation on the real segment downloads: those
    /// still require 206 plus an exact `Content-Range` match before any write.
    static func probeForPartialRestart(
        url: String,
        options: DownloadOptions = DownloadOptions()
    ) throws -> ResourceIdentity {
        do {
            return try probeRangeSupport(url: url, options: options)
        } catch let TransferError.invalidRangeResponse(status) where status == 200 {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dm-restart-probe-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: temp) }
            let outcome = try downloadSingleStream(
                url: url,
                partialURL: temp,
                options: options,
                bodyByteLimit: 1
            )
            return outcome.identity
        }
    }

    /// Probe range support with a tiny ranged GET (`bytes=0-0`). HEAD is advisory-only.
    public static func probeRangeSupport(
        url: String,
        options: DownloadOptions = DownloadOptions()
    ) throws -> ResourceIdentity {
        try observeRangeProbe(url: url, options: options).identity
    }

    struct RangeProbeOutcome: Sendable, Equatable {
        let identity: ResourceIdentity
        let bytesWritten: Int64
    }

    static func observeRangeProbe(
        url: String,
        options: DownloadOptions = DownloadOptions()
    ) throws -> RangeProbeOutcome {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-range-probe-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temp) }

        let outcome = try downloadSingleStream(
            url: url,
            partialURL: temp,
            rangeHeader: "0-0",
            fileOffset: 0,
            options: options,
            bodyByteLimit: 1
        )
        return RangeProbeOutcome(identity: outcome.identity, bytesWritten: outcome.bytesWritten)
    }

    public static func totalLength(from identity: ResourceIdentity) -> Int64? {
        if let contentRange = identity.contentRange {
            if let slash = contentRange.lastIndex(of: "/") {
                let totalPart = contentRange[contentRange.index(after: slash)...]
                if let value = Int64(totalPart) { return value }
            }
        }
        return identity.contentLength
    }

    private static func performDownload(
        url: String,
        fd: Int32,
        fileOffset: Int64,
        rangeHeader: String?,
        options: DownloadOptions,
        abortFlag: TransferAbortFlag?,
        onProgress: ProgressHandler?,
        bodyByteLimit: Int64,
        allowFullBodyOn200: Bool,
        result: inout DMCurlDownloadResult
    ) -> CURLcode {
        let connect = Int(options.connectTimeoutMilliseconds)
        let transfer = Int(options.transferTimeoutMilliseconds)
        let redirects = Int(options.maxRedirects)
        let abortToken = abortFlag?.cToken
        // Per-transfer cap and the shared global/per-host ceilings are separate
        // mechanisms: the first is this transfer's own budget, the second is a
        // queue every concurrent transfer waits in. Both are charged the same
        // delta and the caller waits for whichever is slower.
        let governor: SyncBandwidthGovernor? = options.maxBytesPerSecond > 0
            ? SyncBandwidthGovernor(bytesPerSecond: options.maxBytesPerSecond)
            : nil
        let meter: RateLimitedProgressMeter? = {
            guard let limiter = options.rateLimiter,
                  limiter.isLimited(host: options.rateLimitHost)
            else { return nil }
            return RateLimitedProgressMeter(limiter: limiter, host: options.rateLimitHost)
        }()
        let gatedProgress: ProgressHandler? = {
            guard governor != nil || meter != nil else { return onProgress }
            return { written, total in
                governor?.noteProgress(totalWritten: written)
                meter?.noteProgress(totalWritten: written)
                onProgress?(written, total)
            }
        }()
        return withProgressContext(gatedProgress) { progressCtx in
            url.withCString { urlC in
                withOptionalCString(options.userpwd) { userpwdC in
                    withOptionalCString(options.proxyURL) { proxyC in
                        withOptionalCString(options.cookieJarPath) { cookieC in
                            withOptionalCString(options.extraHeadersCurlPayload) { headersC in
                                if let rangeHeader {
                                    return rangeHeader.withCString { rangeC in
                                        DMCurlEasyDownloadToFD(
                                            urlC,
                                            fd,
                                            curl_off_t(fileOffset),
                                            rangeC,
                                            connect,
                                            transfer,
                                            redirects,
                                            abortToken,
                                            progressCtx.callback,
                                            progressCtx.userdata,
                                            userpwdC,
                                            proxyC,
                                            cookieC,
                                            headersC,
                                            curl_off_t(max(bodyByteLimit, 0)),
                                            allowFullBodyOn200 ? 1 : 0,
                                            &result
                                        )
                                    }
                                }
                                return DMCurlEasyDownloadToFD(
                                    urlC,
                                    fd,
                                    curl_off_t(fileOffset),
                                    nil,
                                    connect,
                                    transfer,
                                    redirects,
                                    abortToken,
                                    progressCtx.callback,
                                    progressCtx.userdata,
                                    userpwdC,
                                    proxyC,
                                    cookieC,
                                    headersC,
                                    curl_off_t(max(bodyByteLimit, 0)),
                                    allowFullBodyOn200 ? 1 : 0,
                                    &result
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private static func withOptionalCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        guard let value else { return body(nil) }
        return value.withCString { body($0) }
    }

    private struct ProgressContext {
        let callback: DMCurlProgressCallback?
        let userdata: UnsafeMutableRawPointer?
        let box: ProgressBox?
    }

    private final class ProgressBox {
        let handler: ProgressHandler
        init(_ handler: @escaping ProgressHandler) {
            self.handler = handler
        }
    }

    private static func withProgressContext<T>(
        _ onProgress: ProgressHandler?,
        _ body: (ProgressContext) -> T
    ) -> T {
        guard let onProgress else {
            return body(ProgressContext(callback: nil, userdata: nil, box: nil))
        }
        let box = ProgressBox(onProgress)
        let unmanaged = Unmanaged.passRetained(box)
        defer { unmanaged.release() }
        let callback: DMCurlProgressCallback = { written, total, userdata in
            guard let userdata else { return 0 }
            let box = Unmanaged<ProgressBox>.fromOpaque(userdata).takeUnretainedValue()
            let knownTotal: Int64? = total > 0 ? Int64(total) : nil
            box.handler(Int64(written), knownTotal)
            return 0
        }
        return body(ProgressContext(
            callback: callback,
            userdata: unmanaged.toOpaque(),
            box: box
        ))
    }
}

/// Atomic same-volume promotion after verification (FR-FS-004 / FR-TRN finalization).
public enum TransferFinalizer {
    public enum FinalizerError: Error, Equatable, Sendable {
        case sizeMismatch(expected: Int64, actual: Int64)
        case missingPartial
        case renameFailed
    }

    public static func promote(
        partialURL: URL,
        finalURL: URL,
        expectedSize: Int64?
    ) throws {
        let values = try partialURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw FinalizerError.missingPartial }
        let actual = Int64(values.fileSize ?? -1)
        if let expectedSize, actual != expectedSize {
            throw FinalizerError.sizeMismatch(expected: expectedSize, actual: actual)
        }

        let directory = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        do {
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
        } catch {
            throw FinalizerError.renameFailed
        }
    }
}
