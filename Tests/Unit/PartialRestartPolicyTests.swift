// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import TransferCore

final class PartialRestartPolicyTests: XCTestCase {
    private func identity(
        httpStatus: Int,
        contentLength: Int64? = nil,
        contentRange: String? = nil
    ) -> TransferCore.ResourceIdentity {
        TransferCore.ResourceIdentity(
            finalURL: "http://127.0.0.1/fixture",
            contentLength: contentLength,
            contentType: nil,
            etag: nil,
            lastModified: nil,
            acceptRanges: httpStatus == 206 ? "bytes" : nil,
            contentDisposition: nil,
            contentRange: contentRange,
            httpStatus: httpStatus
        )
    }

    func testFreshDownloadWhenPartialEmpty() {
        XCTAssertEqual(
            PartialRestartPolicy.classify(existingBytes: 0, probe: identity(httpStatus: 200, contentLength: 4096)),
            .freshDownload
        )
    }

    func testResumeWhenRangeProbeSucceedsAndBytesRemain() {
        XCTAssertEqual(
            PartialRestartPolicy.classify(
                existingBytes: 1024,
                probe: identity(httpStatus: 206, contentLength: 4096, contentRange: "bytes 0-0/4096")
            ),
            .resumeFromOffset(existing: 1024, total: 4096)
        )
    }

    func testRestartViaReplacementWhenRangesUnavailable() {
        XCTAssertEqual(
            PartialRestartPolicy.classify(
                existingBytes: 1024,
                probe: identity(httpStatus: 200, contentLength: 4096)
            ),
            .restartViaReplacement(existing: 1024, total: 4096)
        )
    }

    func testAmbiguousShellWhenSizeMatchesRemoteTotal() {
        XCTAssertEqual(
            PartialRestartPolicy.classify(
                existingBytes: 4096,
                probe: identity(httpStatus: 200, contentLength: 4096)
            ),
            .ambiguousPreallocatedShell(total: 4096)
        )
    }

    func testUnknownRemoteTotalPreservesPartial() {
        XCTAssertEqual(
            PartialRestartPolicy.classify(
                existingBytes: 512,
                probe: identity(httpStatus: 200, contentLength: nil)
            ),
            .unknownRemoteTotal(existing: 512)
        )
    }
}
