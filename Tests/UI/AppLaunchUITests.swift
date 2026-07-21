// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Primary-workflow UI automation (`03-design-system-ui-ux.md` §16). Requires an
/// interactive, automation-permitted session; it is wired into the UI plan and run
/// on a physical/VM UI lane, not the headless fast gate.
@MainActor
final class AppLaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsLibraryWindow() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "main window should appear")
        app.terminate()
    }

    func testInspectorToggleShortcut() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        // ⌥⌘I toggles the inspector; assert the app remains responsive.
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(app.windows.firstMatch.exists)
        app.terminate()
    }
}
