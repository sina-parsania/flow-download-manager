// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TransferCore
import XCTest

final class TransferFinalizerTests: XCTestCase {
    func testPromoteRejectsSizeMismatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-finalizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("a.partial")
        let final = root.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: partial)

        XCTAssertThrowsError(
            try TransferFinalizer.promote(partialURL: partial, finalURL: final, expectedSize: 99)
        ) { error in
            guard case TransferFinalizer.FinalizerError.sizeMismatch = error else {
                return XCTFail("expected sizeMismatch, got \(error)")
            }
        }
    }
}
