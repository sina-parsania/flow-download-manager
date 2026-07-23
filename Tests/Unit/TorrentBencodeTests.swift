// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TorrentCore
import XCTest

final class TorrentBencodeTests: XCTestCase {
    func testDecodeIntegerAndString() throws {
        let data = Data("d4:infod4:name8:film.mp46:lengthi1024eee".utf8)
        let meta = try TorrentBencode.metadata(fromTorrentFile: data)
        XCTAssertEqual(meta.name, "film.mp4")
        XCTAssertEqual(meta.totalLength, 1024)
        XCTAssertEqual(meta.files.count, 1)
    }

    func testRejectsTraversalPathsInMultiFile() throws {
        // info.files[0].path = ["..","etc","passwd"] should be skipped
        let payload = "d4:infod4:name3:set5:filesld6:lengthi10e4:pathl2:..3:etc6:passwdeeeee"
        let meta = try TorrentBencode.metadata(fromTorrentFile: Data(payload.utf8))
        XCTAssertTrue(meta.files.isEmpty)
        XCTAssertEqual(meta.totalLength, 0)
    }
}
