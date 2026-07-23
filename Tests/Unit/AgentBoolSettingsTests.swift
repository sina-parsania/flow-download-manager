// SPDX-License-Identifier: GPL-3.0-or-later

import EngineAgent
import Foundation
import XCTest

final class AgentBoolSettingsTests: XCTestCase {
    func testZipAutoExtractDefaultsTrueWhenUnset() throws {
        let suiteName = "dm.agentbool.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: AgentBoolSettings.zipAutoExtractEnabledKey))
        XCTAssertTrue(
            AgentBoolSettings.bool(
                forKey: AgentBoolSettings.zipAutoExtractEnabledKey,
                defaults: defaults
            )
        )
    }

    func testZipAutoExtractRoundTripFalse() throws {
        let suiteName = "dm.agentbool.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(
            AgentBoolSettings.setBool(
                false,
                forKey: AgentBoolSettings.zipAutoExtractEnabledKey,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            AgentBoolSettings.bool(
                forKey: AgentBoolSettings.zipAutoExtractEnabledKey,
                defaults: defaults
            )
        )
    }

    func testUnknownKeyRejected() throws {
        let suiteName = "dm.agentbool.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AgentBoolSettings.setBool(true, forKey: "notAllowlisted", defaults: defaults))
        XCTAssertFalse(AgentBoolSettings.bool(forKey: "notAllowlisted", defaults: defaults))
    }
}
