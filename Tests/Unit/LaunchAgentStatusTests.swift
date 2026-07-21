// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Presentation

/// Stub manager driving the LaunchAgent model without a real `SMAppService`.
private final class StubLaunchAgent: LaunchAgentManaging, @unchecked Sendable {
    var status: LaunchAgentStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LaunchAgentStatus) {
        self.status = status
    }

    func currentStatus() -> LaunchAgentStatus {
        status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

final class LaunchAgentStatusTests: XCTestCase {
    func testStatusCopyAndFlags() {
        XCTAssertTrue(LaunchAgentStatus.enabled.isOperational)
        XCTAssertFalse(LaunchAgentStatus.notRegistered.isOperational)
        XCTAssertTrue(LaunchAgentStatus.requiresApproval.needsSystemSettingsApproval)
        XCTAssertFalse(LaunchAgentStatus.enabled.needsSystemSettingsApproval)
        for status: LaunchAgentStatus in [.notRegistered, .enabled, .requiresApproval, .notFound, .unknown(9)] {
            XCTAssertFalse(status.headline.isEmpty)
            XCTAssertFalse(status.detail.isEmpty)
        }
    }

    @MainActor
    func testModelRegisterSuccess() {
        let stub = StubLaunchAgent(status: .notRegistered)
        let model = LaunchAgentModel(manager: stub)
        XCTAssertEqual(model.status, .notRegistered)
        model.register()
        XCTAssertEqual(model.status, .enabled)
        XCTAssertNil(model.lastErrorMessage)
        XCTAssertEqual(stub.registerCount, 1)
    }

    @MainActor
    func testModelRegisterFailureSurfacesRedactedMessage() {
        let stub = StubLaunchAgent(status: .notRegistered)
        stub.registerError = NSError(domain: "SMAppService", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "/Users/secret/path denied"
        ])
        let model = LaunchAgentModel(manager: stub)
        model.register()
        XCTAssertNotNil(model.lastErrorMessage)
        XCTAssertFalse(model.lastErrorMessage?.contains("/Users/secret") ?? true, "must not leak paths")
    }

    @MainActor
    func testModelUnregister() {
        let stub = StubLaunchAgent(status: .enabled)
        let model = LaunchAgentModel(manager: stub)
        model.unregister()
        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertEqual(stub.unregisterCount, 1)
    }
}
