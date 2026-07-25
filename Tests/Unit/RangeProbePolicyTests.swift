// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import TransferCore

final class RangeProbePolicyTests: XCTestCase {
    func testCookieHeaderSkipsProbe() {
        var options = TransferCore.DownloadOptions()
        options.extraHeaders = [TransferCore.HTTPHeader(name: "Cookie", value: "a=b")]
        XCTAssertTrue(
            RangeProbePolicy.shouldSkipProbe(url: "https://cdn.example/file.bin", options: options)
        )
    }

    func testEmptyCookieValueDoesNotSkip() {
        var options = TransferCore.DownloadOptions()
        options.extraHeaders = [TransferCore.HTTPHeader(name: "Cookie", value: "")]
        XCTAssertFalse(
            RangeProbePolicy.shouldSkipProbe(url: "https://cdn.example/file.bin", options: options)
        )
    }

    func testAuthorizationHeaderSkipsProbe() {
        var options = TransferCore.DownloadOptions()
        options.extraHeaders = [TransferCore.HTTPHeader(name: "Authorization", value: "Bearer x")]
        XCTAssertTrue(
            RangeProbePolicy.shouldSkipProbe(url: "https://cdn.example/file.bin", options: options)
        )
    }

    func testEmptyAuthorizationDoesNotSkip() {
        var options = TransferCore.DownloadOptions()
        options.extraHeaders = [TransferCore.HTTPHeader(name: "Authorization", value: "")]
        XCTAssertFalse(
            RangeProbePolicy.shouldSkipProbe(url: "https://cdn.example/file.bin", options: options)
        )
    }

    func testCaseInsensitiveAuthorizationSkipsProbe() {
        var options = TransferCore.DownloadOptions()
        options.extraHeaders = [TransferCore.HTTPHeader(name: "authorization", value: "x")]
        XCTAssertTrue(
            RangeProbePolicy.shouldSkipProbe(url: "https://cdn.example/file.bin", options: options)
        )
    }

    func testUserpwdSkipsProbe() {
        var options = TransferCore.DownloadOptions()
        options.userpwd = "alice:secret"
        XCTAssertTrue(
            RangeProbePolicy.shouldSkipProbe(url: "https://cdn.example/file.bin", options: options)
        )
    }

    func testEmptyUserpwdDoesNotSkip() {
        var options = TransferCore.DownloadOptions()
        options.userpwd = ""
        XCTAssertFalse(
            RangeProbePolicy.shouldSkipProbe(url: "https://cdn.example/file.bin", options: options)
        )
    }

    func testCookieJarPathSkipsProbe() {
        var options = TransferCore.DownloadOptions()
        options.cookieJarPath = "/tmp/session.jar"
        XCTAssertTrue(
            RangeProbePolicy.shouldSkipProbe(url: "https://cdn.example/file.bin", options: options)
        )
    }

    func testEmptyCookieJarPathDoesNotSkip() {
        var options = TransferCore.DownloadOptions()
        options.cookieJarPath = ""
        XCTAssertFalse(
            RangeProbePolicy.shouldSkipProbe(url: "https://cdn.example/file.bin", options: options)
        )
    }

    func testPlainURLDoesNotSkip() {
        XCTAssertFalse(
            RangeProbePolicy.looksLikeFragileSignedURL("https://cdn.example/files/movie.mp4")
        )
        XCTAssertFalse(
            RangeProbePolicy.shouldSkipProbe(
                url: "https://cdn.example/files/movie.mp4",
                options: TransferCore.DownloadOptions()
            )
        )
    }

    func testGenericSigQueryIsFragile() {
        XCTAssertTrue(
            RangeProbePolicy.looksLikeFragileSignedURL(
                "https://files.example/content?id=1&sig=abcdef&ts=99"
            )
        )
    }

    func testSignatureAndAuthKeyAreFragile() {
        XCTAssertTrue(
            RangeProbePolicy.looksLikeFragileSignedURL(
                "https://edge.example/a.bin?signature=deadbeef&expires=999"
            )
        )
        XCTAssertTrue(
            RangeProbePolicy.looksLikeFragileSignedURL(
                "https://edge.example/a.bin?auth_key=1-2-3"
            )
        )
        XCTAssertTrue(
            RangeProbePolicy.looksLikeFragileSignedURL(
                "https://edge.example/a.bin?download_token=xyz"
            )
        )
    }

    func testExpiresWithTokenIsFragile() {
        XCTAssertTrue(
            RangeProbePolicy.looksLikeFragileSignedURL(
                "https://edge.example/a.bin?expires=1700000000&token=abc"
            )
        )
    }

    func testExpiresAloneIsNotFragile() {
        XCTAssertFalse(
            RangeProbePolicy.looksLikeFragileSignedURL(
                "https://cdn.example/a.bin?expires=1700000000"
            )
        )
    }

    func testAWSSignedURLKeepsProbeForSegmentation() {
        let url = "https://bucket.s3.amazonaws.com/key?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIA%2F20260101%2Fus-east-1%2Fs3%2Faws4_request"
            + "&X-Amz-Signature=abcdef"
        XCTAssertFalse(RangeProbePolicy.looksLikeFragileSignedURL(url))
        XCTAssertFalse(
            RangeProbePolicy.shouldSkipProbe(url: url, options: TransferCore.DownloadOptions())
        )
    }

    func testGCSSignedURLKeepsProbe() {
        let url = "https://storage.googleapis.com/bucket/obj?X-Goog-Algorithm=GOOG4-RSA-SHA256"
            + "&X-Goog-Signature=abc"
        XCTAssertFalse(RangeProbePolicy.looksLikeFragileSignedURL(url))
    }

    func testAzureSASKeepsProbe() {
        let url = "https://account.blob.core.windows.net/c/b.bin?sv=2023-01-03&se=2026-01-01"
            + "T00%3A00%3A00Z&sr=b&sp=r&sig=abc%3D"
        XCTAssertFalse(RangeProbePolicy.looksLikeFragileSignedURL(url))
    }

    func testCookieStillSkipsEvenOnAWSURL() {
        let url = "https://bucket.s3.amazonaws.com/key?X-Amz-Signature=abcdef"
        var options = TransferCore.DownloadOptions()
        options.extraHeaders = [TransferCore.HTTPHeader(name: "Cookie", value: "sid=1")]
        XCTAssertTrue(RangeProbePolicy.shouldSkipProbe(url: url, options: options))
    }

    func testQueryKeyMatchingIsCaseInsensitive() {
        XCTAssertTrue(
            RangeProbePolicy.looksLikeFragileSignedURL(
                "https://edge.example/a.bin?SIG=ABCDEF"
            )
        )
        XCTAssertFalse(
            RangeProbePolicy.looksLikeFragileSignedURL(
                "https://bucket.s3.amazonaws.com/key?x-amz-signature=abcdef"
            )
        )
    }
}
