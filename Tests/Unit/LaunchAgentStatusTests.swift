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
    func testModelRegisterSuccess() async {
        let stub = StubLaunchAgent(status: .notRegistered)
        let model = LaunchAgentModel(manager: stub)
        XCTAssertEqual(model.status, .notRegistered)
        model.register()
        XCTAssertEqual(model.status, .enabled)
        XCTAssertNil(model.lastErrorMessage)
        XCTAssertEqual(stub.registerCount, 1)
        // Registration alone is not readiness — ensureRunning marks ready without a probe client.
        XCTAssertFalse(model.isEngineReady)
        await model.ensureRunning()
        XCTAssertTrue(model.isOperational)
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
    func testEnsureRunningRegistersWhenOff() async throws {
        let stub = StubLaunchAgent(status: .notRegistered)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test.engine.ensure.\(UUID().uuidString)"))
        let model = LaunchAgentModel(manager: stub, defaults: defaults)
        await model.ensureRunning()
        XCTAssertEqual(stub.registerCount, 1)
        XCTAssertEqual(model.status, .enabled)
        XCTAssertTrue(model.isOperational)
    }

    @MainActor
    func testEnsureRunningNoopWhenAlreadyEnabledSamePath() async throws {
        let stub = StubLaunchAgent(status: .enabled)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test.engine.ensure2.\(UUID().uuidString)"))
        defaults.set(Bundle.main.bundleURL.path, forKey: "engine.lastRegisteredBundlePath")
        let model = LaunchAgentModel(manager: stub, defaults: defaults)
        await model.ensureRunning()
        XCTAssertEqual(stub.registerCount, 0)
        XCTAssertTrue(model.isOperational)
    }

    @MainActor
    func testRepairUnregistersBrokenSMService() async throws {
        let stub = StubLaunchAgent(status: .enabled)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test.engine.repair.\(UUID().uuidString)"))
        let model = LaunchAgentModel(manager: stub, defaults: defaults)
        await model.repair()
        XCTAssertEqual(stub.unregisterCount, 1)
        XCTAssertEqual(stub.status, .notRegistered)
        XCTAssertEqual(model.runtimeMode, .directChild)
        XCTAssertTrue(model.isEngineReady)
    }

    @MainActor
    func testEnsureRunningMarksReadyWithoutProbeWhenEnabled() async throws {
        let stub = StubLaunchAgent(status: .enabled)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test.engine.ensure3.\(UUID().uuidString)"))
        defaults.set(Bundle.main.bundleURL.path, forKey: "engine.lastRegisteredBundlePath")
        let model = LaunchAgentModel(manager: stub, defaults: defaults)
        await model.ensureRunning()
        XCTAssertTrue(model.isEngineReady)
        XCTAssertEqual(model.runtimeMode, .smAppService)
    }
}
