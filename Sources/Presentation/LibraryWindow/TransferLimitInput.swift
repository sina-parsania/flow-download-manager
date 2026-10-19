// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XPCContracts

/// Client-side validation for the Add sheet's optional per-download limits.
///
/// Pure and view-free so the rules are unit-testable: the sheet only renders the
/// message this returns. Blank input always means "no override", never zero.
enum TransferLimitInput {
    struct Validated: Equatable {
        var expectedChecksumSHA256: String?
        var maxBytesPerSecond: Int64?
        var preferredConnectionCount: Int?
    }

    enum Outcome: Equatable {
        case success(Validated)
        case failure(String)
    }

    /// Megabytes here are decimal (1 MB/s = 1,000,000 bytes/s), matching how
    /// download speeds are advertised and how the row formatter reads them back.
    private static let bytesPerMegabyte: Double = 1_000_000

    static func validate(
        checksum: String,
        speedLimitMegabytesPerSecond: String,
        connectionCount: String,
        itemCount: Int
    ) -> Outcome {
        var validated = Validated()

        let checksumInput = checksum.trimmingCharacters(in: .whitespacesAndNewlines)
        if !checksumInput.isEmpty {
            guard let normalized = ChecksumFormat.normalizedSHA256(checksumInput) else {
                return .failure(
                    "The expected SHA-256 must be exactly \(ChecksumFormat.sha256HexLength) "
                        + "characters using 0-9 and a-f."
                )
            }
            guard itemCount == 1 else {
                return .failure(
                    "A checksum describes one file. Queue a single link, or clear the checksum."
                )
            }
            validated.expectedChecksumSHA256 = normalized
        }

        let speedInput = speedLimitMegabytesPerSecond.trimmingCharacters(in: .whitespacesAndNewlines)
        if !speedInput.isEmpty {
            // Accept a comma decimal mark so the field reads naturally in locales
            // that write 2,5 rather than 2.5.
            let normalized = speedInput.replacingOccurrences(of: ",", with: ".")
            let ceiling = Double(EngineXPC.maxJobBytesPerSecond) / bytesPerMegabyte
            guard let megabytes = Double(normalized), megabytes.isFinite,
                  megabytes > 0, megabytes <= ceiling
            else {
                return .failure(
                    "The speed limit must be a number of megabytes per second, such as 2.5."
                )
            }
            let bytes = Int64((megabytes * bytesPerMegabyte).rounded())
            guard bytes >= 1 else {
                return .failure("That speed limit rounds down to nothing. Try 0.01 or more.")
            }
            validated.maxBytesPerSecond = bytes
        }

        let connectionsInput = connectionCount.trimmingCharacters(in: .whitespacesAndNewlines)
        if !connectionsInput.isEmpty {
            guard let value = Int(connectionsInput),
                  value >= 1, value <= EngineXPC.maxPreferredConnectionCount
            else {
                return .failure(
                    "Connections must be a whole number from 1 to "
                        + "\(EngineXPC.maxPreferredConnectionCount)."
                )
            }
            validated.preferredConnectionCount = value
        }

        return .success(validated)
    }
}
