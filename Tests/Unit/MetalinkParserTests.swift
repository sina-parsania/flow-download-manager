// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TransferCore
import XCTest

final class MetalinkParserTests: XCTestCase {
    func testParsesMirrorsSizeAndChecksum() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="pkg.dmg">
            <size>2048</size>
            <hash type="sha-256">aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899</hash>
            <url preference="10">https://cdn.example/pkg.dmg</url>
            <url preference="20">https://mirror.example/pkg.dmg</url>
          </file>
        </metalink>
        """
        let doc = try MetalinkParser.parse(xml: Data(xml.utf8))
        XCTAssertEqual(doc.files.count, 1)
        let file = try XCTUnwrap(doc.files.first)
        XCTAssertEqual(file.name, "pkg.dmg")
        XCTAssertEqual(file.size, 2048)
        XCTAssertTrue(file.hasProvenIdentity)
        XCTAssertEqual(file.mirrors.first?.url, "https://cdn.example/pkg.dmg")
        XCTAssertEqual(file.mirrors.count, 2)
    }

    func testRejectsEmptyMirrors() {
        let xml = """
        <?xml version="1.0"?>
        <metalink><file name="x"><size>1</size></file></metalink>
        """
        XCTAssertThrowsError(try MetalinkParser.parse(xml: Data(xml.utf8))) { error in
            XCTAssertEqual(error as? MetalinkParser.ParseError, .emptyMirrors)
        }
    }

    func testIdentityRequiresStrongChecksum() throws {
        let xml = """
        <?xml version="1.0"?>
        <metalink>
          <file name="a.bin">
            <size>10</size>
            <hash type="md5">d41d8cd98f00b204e9800998ecf8427e</hash>
            <url>https://example.com/a.bin</url>
          </file>
        </metalink>
        """
        let file = try XCTUnwrap(try MetalinkParser.parse(xml: Data(xml.utf8)).files.first)
        XCTAssertFalse(file.hasProvenIdentity)
    }
}
