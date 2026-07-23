// SPDX-License-Identifier: GPL-3.0-or-later

import CCurl
import Darwin
import Foundation
import TransferCurlBridge

/// Single-stream and ranged transfer orchestration over the pinned libcurl stack
/// (FR-TRN-001…009 foundation). Multi-socket adaptive segmentation builds on this.
public enum TransferCore {
    public struct DownloadOptions: Sendable, Equatable {
        public var connectTimeoutMilliseconds: Int
        public var transferTimeoutMilliseconds: Int
        public var maxRedirects: Int
        /// HTTP basic/digest credentials as `user:password`. Never log this value.
        public var userpwd: String?
        /// Proxy URL such as `http://host:8080` or `socks5://host:1080`.
        public var proxyURL: String?
        /// Netscape cookie jar path for CURLOPT_COOKIEFILE / CURLOPT_COOKIEJAR.
        public var cookieJarPath: String?

        public init(
            connectTimeoutMilliseconds: Int = 15000,
            transferTimeoutMilliseconds: Int = 0,
            maxRedirects: Int = 10,
            userpwd: String? = nil,
            proxyURL: String? = nil,
            cookieJarPath: String? = nil
        ) {
            self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
            self.transferTimeoutMilliseconds = transferTimeoutMilliseconds
            self.maxRedirects = maxRedirects
            self.userpwd = userpwd
            self.proxyURL = proxyURL
            self.cookieJarPath = cookieJarPath
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
        case emptyURL
        case fileOpenFailed
        case incompleteWrite(expected: Int64?, wrote: Int64)
        case unsupportedScheme(String)
        case aborted
    }

    public typealias ProgressHandler = @Sendable (Int64) -> Void

    /// Downloads `url` into a sibling partial file at `partialURL` using positioned writes.
    public static func downloadSingleStream(
        url: String,
        partialURL: URL,
        rangeHeader: String? = nil,
        fileOffset: Int64 = 0,
        options: DownloadOptions = DownloadOptions(),
        abortFlag: TransferAbortFlag? = nil,
        onProgress: ProgressHandler? = nil
    ) throws -> TransferOutcome {
        try CurlBridge.initialize()

        let parsed = try CurlURLParser.parse(url)
        guard parsed.isPhase1Supported else {
            throw TransferError.unsupportedScheme(parsed.scheme)
        }

        let directory = partialURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = partialURL.path.withCString { path in
            open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
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
            result: &result
        )

        if code == CURLE_ABORTED_BY_CALLBACK || abortFlag?.isSet == true {
            throw TransferError.aborted
        }
        guard code == CURLE_OK else {
            throw TransferError.curl(code)
        }

        let status = Int(result.httpStatus)
        let successStatuses: Set<Int> = rangeHeader == nil ? [200] : [200, 206]
        guard successStatuses.contains(status) else {
            throw TransferError.httpStatus(status)
        }

        let contentLength: Int64? = result.contentLength >= 0 ? Int64(result.contentLength) : nil
        if rangeHeader == nil, let contentLength, result.bytesWritten != contentLength {
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

    /// Resume an existing partial when the server supports ranges; otherwise restart.
    public static func resumeOrDownload(
        url: String,
        partialURL: URL,
        options: DownloadOptions = DownloadOptions(),
        abortFlag: TransferAbortFlag? = nil,
        onProgress: ProgressHandler? = nil
    ) throws -> TransferOutcome {
        let existing = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        guard existing > 0 else {
            return try downloadSingleStream(
                url: url,
                partialURL: partialURL,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress
            )
        }

        let probe = try probeRangeSupport(url: url, options: options)
        guard probe.httpStatus == 206,
              let total = totalLength(from: probe),
              existing < total
        else {
            try? FileManager.default.removeItem(at: partialURL)
            return try downloadSingleStream(
                url: url,
                partialURL: partialURL,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress
            )
        }

        let progress: ProgressHandler? = if let onProgress {
            { written in onProgress(existing + written) }
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
        let attrs = try FileManager.default.attributesOfItem(atPath: partialURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
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

    /// Probe range support with a tiny ranged GET (`bytes=0-0`). HEAD is advisory-only.
    public static func probeRangeSupport(
        url: String,
        options: DownloadOptions = DownloadOptions()
    ) throws -> ResourceIdentity {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-range-probe-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temp) }

        let outcome = try downloadSingleStream(
            url: url,
            partialURL: temp,
            rangeHeader: "0-0",
            fileOffset: 0,
            options: options
        )
        return outcome.identity
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
        result: inout DMCurlDownloadResult
    ) -> CURLcode {
        let connect = Int(options.connectTimeoutMilliseconds)
        let transfer = Int(options.transferTimeoutMilliseconds)
        let redirects = Int(options.maxRedirects)
        let abortPtr: UnsafeMutablePointer<Int32>? = abortFlag.map(\.pointer)
        return withProgressContext(onProgress) { progressCtx in
            url.withCString { urlC in
                withOptionalCString(options.userpwd) { userpwdC in
                    withOptionalCString(options.proxyURL) { proxyC in
                        withOptionalCString(options.cookieJarPath) { cookieC in
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
                                        abortPtr,
                                        progressCtx.callback,
                                        progressCtx.userdata,
                                        userpwdC,
                                        proxyC,
                                        cookieC,
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
                                abortPtr,
                                progressCtx.callback,
                                progressCtx.userdata,
                                userpwdC,
                                proxyC,
                                cookieC,
                                &result
                            )
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
        let callback: DMCurlProgressCallback = { written, userdata in
            guard let userdata else { return 0 }
            let box = Unmanaged<ProgressBox>.fromOpaque(userdata).takeUnretainedValue()
            box.handler(Int64(written))
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
