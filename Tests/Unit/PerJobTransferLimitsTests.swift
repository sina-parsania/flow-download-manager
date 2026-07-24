// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TransferCore
import XCTest
import XPCContracts
@testable import EngineAgent
@testable import Presentation

/// Shape validation, client-side field parsing, and the precedence/clamp rules
/// for the per-download checksum, speed limit and connection count.
final class PerJobTransferLimitsTests: XCTestCase {
    private let validDigest = String(repeating: "0123456789abcdef", count: 4)

    // MARK: - Checksum shape

    func testValidDigestIsAcceptedUnchanged() {
        XCTAssertEqual(ChecksumFormat.normalizedSHA256(validDigest), validDigest)
    }

    func testUppercaseDigestIsNormalizedToLowercase() {
        let upper = validDigest.uppercased()
        XCTAssertEqual(ChecksumFormat.normalizedSHA256(upper), validDigest)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(ChecksumFormat.normalizedSHA256("  \(validDigest)\n"), validDigest)
    }

    func testShortAndLongDigestsAreRejected() {
        XCTAssertNil(ChecksumFormat.normalizedSHA256(String(validDigest.dropLast())))
        XCTAssertNil(ChecksumFormat.normalizedSHA256(validDigest + "a"))
    }

    func testNonHexCharactersAreRejected() {
        XCTAssertNil(ChecksumFormat.normalizedSHA256(String(validDigest.dropLast()) + "g"))
        XCTAssertNil(ChecksumFormat.normalizedSHA256(String(validDigest.dropLast()) + "-"))
    }

    func testFullWidthDigitsAreRejected() {
        // `Character.isHexDigit` accepts these; a real digest never contains them.
        let fullWidth = String(validDigest.dropLast()) + "\u{FF10}"
        XCTAssertNil(ChecksumFormat.normalizedSHA256(fullWidth))
    }

    func testEmptyInputIsRejected() {
        XCTAssertNil(ChecksumFormat.normalizedSHA256(""))
        XCTAssertNil(ChecksumFormat.normalizedSHA256("   "))
    }

    // MARK: - Add sheet field validation

    private func validate(
        checksum: String = "",
        speed: String = "",
        connections: String = "",
        itemCount: Int = 1
    ) -> TransferLimitInput.Outcome {
        TransferLimitInput.validate(
            checksum: checksum,
            speedLimitMegabytesPerSecond: speed,
            connectionCount: connections,
            itemCount: itemCount
        )
    }

    func testBlankFieldsProduceNoOverrides() {
        XCTAssertEqual(
            validate(checksum: "  ", speed: "", connections: " ", itemCount: 40),
            .success(TransferLimitInput.Validated())
        )
    }

    func testChecksumIsAcceptedForASingleLink() {
        XCTAssertEqual(
            validate(checksum: validDigest.uppercased(), itemCount: 1),
            .success(TransferLimitInput.Validated(expectedChecksumSHA256: validDigest))
        )
    }

    func testChecksumIsRefusedForMultipleLinks() {
        guard case let .failure(message) = validate(checksum: validDigest, itemCount: 2) else {
            return XCTFail("a batch-wide checksum across several links must be refused")
        }
        XCTAssertTrue(message.contains("single link"), message)
    }

    func testMalformedChecksumFailsWithAMessage() {
        guard case let .failure(message) = validate(checksum: "not-a-digest") else {
            return XCTFail("a malformed checksum must be refused")
        }
        XCTAssertTrue(message.contains("64"), message)
    }

    func testSpeedLimitConvertsMegabytesToBytes() {
        XCTAssertEqual(
            validate(speed: "2.5"),
            .success(TransferLimitInput.Validated(maxBytesPerSecond: 2_500_000))
        )
    }

    func testSpeedLimitAcceptsACommaDecimalMark() {
        XCTAssertEqual(
            validate(speed: "1,5"),
            .success(TransferLimitInput.Validated(maxBytesPerSecond: 1_500_000))
        )
    }

    func testSpeedLimitRejectsZeroNegativeAndText() {
        for input in ["0", "-1", "fast", "1e400"] {
            guard case .failure = validate(speed: input) else {
                return XCTFail("speed limit \"\(input)\" must be refused")
            }
        }
    }

    func testConnectionCountAcceptsTheAllowedRange() {
        XCTAssertEqual(
            validate(connections: "1"),
            .success(TransferLimitInput.Validated(preferredConnectionCount: 1))
        )
        XCTAssertEqual(
            validate(connections: "\(EngineXPC.maxPreferredConnectionCount)"),
            .success(
                TransferLimitInput.Validated(
                    preferredConnectionCount: EngineXPC.maxPreferredConnectionCount
                )
            )
        )
    }

    func testConnectionCountRejectsOutOfRangeAndNonIntegers() {
        let tooMany = "\(EngineXPC.maxPreferredConnectionCount + 1)"
        for input in ["0", "-4", "2.5", "many", tooMany] {
            guard case .failure = validate(connections: input) else {
                return XCTFail("connection count \"\(input)\" must be refused")
            }
        }
    }

    // MARK: - Per-job override precedence

    func testPerJobRateWinsOverTheGlobalPolicy() {
        XCTAssertEqual(
            TransferOrchestrator.effectiveMaxBytesPerSecond(
                perJob: 5_000_000,
                globalPolicyLimit: 1_000_000
            ),
            5_000_000
        )
    }

    func testGlobalPolicyAppliesWhenNoPerJobRate() {
        XCTAssertEqual(
            TransferOrchestrator.effectiveMaxBytesPerSecond(perJob: nil, globalPolicyLimit: 1_000_000),
            1_000_000
        )
    }

    func testNoLimitWhenNeitherIsPresent() {
        XCTAssertNil(
            TransferOrchestrator.effectiveMaxBytesPerSecond(perJob: nil, globalPolicyLimit: nil)
        )
    }

    func testNonPositivePerJobRateFallsBackToTheGlobalPolicy() {
        XCTAssertEqual(
            TransferOrchestrator.effectiveMaxBytesPerSecond(perJob: 0, globalPolicyLimit: 1_000_000),
            1_000_000
        )
    }

    // MARK: - Retry eligibility

    func testChecksumMismatchIsNotRetried() {
        let mismatch = IntegrityVerifier.VerifyError.checksumMismatch(
            expected: validDigest,
            actual: String(repeating: "f", count: 64)
        )
        XCTAssertFalse(TransferOrchestrator.isRetryable(mismatch))
    }

    func testTransientTransferErrorsStayRetryable() {
        XCTAssertTrue(TransferOrchestrator.isRetryable(TransferCore.TransferError.httpStatus(503)))
        XCTAssertTrue(TransferOrchestrator.isRetryable(IntegrityVerifier.VerifyError.unreadableFile))
    }

    // MARK: - Connection clamp

    func testConnectionPreferenceNeverExceedsTheSocketBudget() {
        XCTAssertEqual(
            TransferOrchestrator.effectiveHostMaxSegments(
                preferredConnectionCount: 64,
                socketBudget: 8
            ),
            8
        )
    }

    func testConnectionPreferenceBelowTheBudgetIsHonoured() {
        XCTAssertEqual(
            TransferOrchestrator.effectiveHostMaxSegments(
                preferredConnectionCount: 4,
                socketBudget: 32
            ),
            4
        )
    }

    func testNoPreferenceKeepsTheSocketBudgetUnchanged() {
        XCTAssertEqual(
            TransferOrchestrator.effectiveHostMaxSegments(
                preferredConnectionCount: nil,
                socketBudget: 32
            ),
            32
        )
    }

    func testClampNeverDropsBelowOneSegment() {
        XCTAssertEqual(
            TransferOrchestrator.effectiveHostMaxSegments(preferredConnectionCount: 0, socketBudget: 4),
            1
        )
        XCTAssertEqual(
            TransferOrchestrator.effectiveHostMaxSegments(preferredConnectionCount: 4, socketBudget: 0),
            1
        )
    }

    func testSocketReservationAsksForOnlyWhatThePreferenceNeeds() {
        XCTAssertEqual(TransferOrchestrator.requestedExtraSockets(preferredConnectionCount: nil), 31)
        XCTAssertEqual(TransferOrchestrator.requestedExtraSockets(preferredConnectionCount: 1), 0)
        XCTAssertEqual(TransferOrchestrator.requestedExtraSockets(preferredConnectionCount: 8), 7)
        XCTAssertEqual(TransferOrchestrator.requestedExtraSockets(preferredConnectionCount: 64), 31)
    }
}
