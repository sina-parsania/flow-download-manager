// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import MediaIsolation
import XCTest

/// First coverage this resolver has ever had. The bug it replaces was invisible
/// in the repo and only appeared in a shipped bundle: resolution ran from
/// `currentDirectoryPath`, which is the repo root under `swift test` and `/`
/// under a GUI launch, so every released build resolved nothing.
final class MediaHelperLocatorTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-helper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "dm-helper-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeExecutable(_ name: String, permissions: Int16 = 0o755) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - User-chosen path

    func testUserChosenExecutableResolves() throws {
        let helper = try makeExecutable("yt-dlp")
        defaults.set(helper.path, forKey: MediaHelperLocator.userChosenPathDefaultsKey)
        XCTAssertEqual(MediaHelperLocator.userChosenExecutable(defaults: defaults), helper)
    }

    /// A helper the user uninstalled must resolve to nil, not to a stale path
    /// the probe would then fail on with a confusing error.
    func testUserChosenPathThatNoLongerExistsResolvesNil() throws {
        let helper = try makeExecutable("yt-dlp")
        defaults.set(helper.path, forKey: MediaHelperLocator.userChosenPathDefaultsKey)
        try FileManager.default.removeItem(at: helper)
        XCTAssertNil(MediaHelperLocator.userChosenExecutable(defaults: defaults))
    }

    func testNonExecutableUserChosenPathResolvesNil() throws {
        let plain = try makeExecutable("notes.txt", permissions: 0o644)
        defaults.set(plain.path, forKey: MediaHelperLocator.userChosenPathDefaultsKey)
        XCTAssertNil(MediaHelperLocator.userChosenExecutable(defaults: defaults))
    }

    func testEmptyUserChosenPathResolvesNil() {
        defaults.set("", forKey: MediaHelperLocator.userChosenPathDefaultsKey)
        XCTAssertNil(MediaHelperLocator.userChosenExecutable(defaults: defaults))
    }

    func testNoUserChoiceResolvesNil() {
        XCTAssertNil(MediaHelperLocator.userChosenExecutable(defaults: defaults))
    }

    // MARK: - Execution safety

    func testRootOwnedStyleBinaryInATightDirectoryIsSafe() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: root.path
        )
        let helper = try makeExecutable("yt-dlp", permissions: 0o755)
        XCTAssertTrue(MediaHelperLocator.isSafeToExecute(helper))
    }

    /// A world-writable binary can be swapped by any local process between the
    /// check and the run; auto-discovery must not pick it up.
    func testWorldWritableBinaryIsRejected() throws {
        let helper = try makeExecutable("yt-dlp", permissions: 0o777)
        XCTAssertFalse(MediaHelperLocator.isSafeToExecute(helper))
    }

    func testGroupWritableBinaryIsRejected() throws {
        let helper = try makeExecutable("yt-dlp", permissions: 0o775)
        XCTAssertFalse(MediaHelperLocator.isSafeToExecute(helper))
    }

    /// The subtler case: the binary itself is locked down, but anyone can
    /// replace it because its directory is writable. This is the /usr/local/bin
    /// hazard on a migrated Mac.
    func testTightBinaryInAWorldWritableDirectoryIsRejected() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o777))],
            ofItemAtPath: root.path
        )
        let helper = try makeExecutable("yt-dlp", permissions: 0o755)
        XCTAssertFalse(
            MediaHelperLocator.isSafeToExecute(helper),
            "a writable parent directory defeats a locked-down binary"
        )
    }

    // MARK: - Precedence

    /// A binary Flow shipped must always beat one found on the system.
    func testBundledWinsOverUserChosen() throws {
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        let helpers = resources.appendingPathComponent("MediaHelpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let bundled = helpers.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: bundled.path
        )

        let chosen = try makeExecutable("chosen-yt-dlp")
        defaults.set(chosen.path, forKey: MediaHelperLocator.userChosenPathDefaultsKey)

        let bundle = try XCTUnwrap(Bundle(url: root))
        let resolved = MediaHelperLocator.resolve(bundle: bundle, defaults: defaults)
        XCTAssertEqual(resolved?.source, .bundled)
        XCTAssertEqual(resolved?.url.lastPathComponent, "yt-dlp")
    }

    /// An explicit user choice beats auto-discovery, so a user who points Flow
    /// at a specific build gets that build.
    func testUserChosenWinsOverDiscovery() throws {
        let chosen = try makeExecutable("yt-dlp")
        defaults.set(chosen.path, forKey: MediaHelperLocator.userChosenPathDefaultsKey)
        let resolved = MediaHelperLocator.resolve(
            bundle: Bundle(for: MediaHelperLocatorTests.self),
            defaults: defaults
        )
        XCTAssertEqual(resolved?.source, .userChosen)
        XCTAssertEqual(resolved?.url, chosen)
    }

    /// Resolution must not depend on the working directory — the entire defect
    /// being fixed. Running from `/` must give the same answer as anywhere else.
    func testResolutionIsIndependentOfWorkingDirectory() throws {
        let chosen = try makeExecutable("yt-dlp")
        defaults.set(chosen.path, forKey: MediaHelperLocator.userChosenPathDefaultsKey)
        let bundle = Bundle(for: MediaHelperLocatorTests.self)

        let before = MediaHelperLocator.resolve(bundle: bundle, defaults: defaults)
        let previous = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath("/"))
        let after = MediaHelperLocator.resolve(bundle: bundle, defaults: defaults)

        XCTAssertEqual(before?.url, after?.url)
        XCTAssertEqual(after?.url, chosen)
    }
}
