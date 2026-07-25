// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TransferCurlBridge

public extension TransferCore {
    /// Downloads multiple byte ranges concurrently via curl_multi into one partial file.
    static func downloadRangesViaMulti(
        url: String,
        partialURL: URL,
        ranges: [CurlMultiLoop.RangeRequest],
        options: DownloadOptions = DownloadOptions(),
        abortFlag: TransferAbortFlag? = nil,
        onProgress: ProgressHandler? = nil,
        onSegmentProgress: (@Sendable (Int, Int64) -> Void)? = nil,
        maxConcurrent: Int? = nil,
        replicaGroupByRangeIndex: [Int]? = nil
    ) throws -> [CurlMultiLoop.Outcome] {
        let parsed = try CurlURLParser.parse(url)
        guard parsed.isPhase1Supported else {
            throw TransferError.unsupportedScheme(parsed.scheme)
        }
        do {
            let multiProgress: (@Sendable (Int64) -> Void)? = if let onProgress {
                { bytes in onProgress(bytes, nil) }
            } else {
                nil
            }
            return try CurlMultiLoop.downloadRangesToFile(
                url: url,
                partialURL: partialURL,
                ranges: ranges,
                connectTimeoutMilliseconds: options.connectTimeoutMilliseconds,
                transferTimeoutMilliseconds: options.transferTimeoutMilliseconds,
                maxRedirects: options.maxRedirects,
                abortFlag: abortFlag?.cToken,
                userpwd: options.userpwd,
                proxyURL: options.proxyURL,
                cookieJarPath: options.cookieJarPath,
                extraHeadersPayload: options.extraHeadersCurlPayload,
                onProgress: multiProgress,
                onSegmentProgress: onSegmentProgress,
                maxConcurrent: maxConcurrent,
                replicaGroupByRangeIndex: replicaGroupByRangeIndex
            )
        } catch let error as CurlMultiLoop.MultiError {
            switch error {
            case .aborted:
                throw TransferError.aborted
            case let .curl(code):
                throw TransferError.curl(code)
            case let .httpStatus(code):
                throw TransferError.httpStatus(code)
            case let .invalidRangeResponse(httpStatus):
                throw TransferError.invalidRangeResponse(httpStatus: httpStatus)
            case let .incompleteWrite(expected, wrote):
                throw TransferError.incompleteWrite(expected: expected, wrote: wrote)
            case .multiInitFailed, .easyCreateFailed, .multiAddFailed, .emptyRequests:
                throw TransferError.fileOpenFailed
            }
        }
    }
}
