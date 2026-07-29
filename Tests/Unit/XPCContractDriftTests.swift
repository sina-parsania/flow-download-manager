// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ObjectiveC.runtime
import XCTest
import XPCContracts

/// Guards the rule that adding or changing an RPC touches four files together:
/// `EngineControlProtocol`, `EngineControlInterface`, `EngineService`, and
/// `EngineClient` (plus the `capabilities` array in `ClientHello`). Nothing
/// enforced that before — landing three of the four compiles fine and fails at
/// runtime with an opaque decoding error, or silently breaks the handshake gate.
///
/// The check can only be one-sided: `EngineControlProtocol` is `@objc`, so the
/// Objective-C runtime can list its selectors, but `EngineClient` is a plain
/// Swift class and Swift has no method enumeration. So this pins the protocol's
/// selector set to a checked-in list. Adding an RPC fails this test, and
/// updating the list puts the change in a reviewer's diff — which is the moment
/// to confirm the other three files moved too.
final class XPCContractDriftTests: XCTestCase {
    /// Every selector `EngineControlProtocol` requires, sorted.
    /// **Updating this list is a prompt, not a chore**: confirm the new RPC also
    /// landed in `EngineControlInterface.swift`, `EngineService.swift`, and
    /// `EngineClient.swift`, and that `ClientHello.capabilities` names it.
    private static let expectedSelectors: [String] = [
        "clearEvents:reply:",
        "controlJob:reply:",
        "deleteHostSetting:reply:",
        "deleteJob:reply:",
        "enqueueBatch:reply:",
        "getBandwidthPolicyWithRequestID:reply:",
        "getBoolSetting:reply:",
        "getDefaultDestinationWithRequestID:reply:",
        "getJobTransferSettings:reply:",
        "handshake:reply:",
        "healthStatusWithRequestID:reply:",
        "listCategoryRulesWithRequestID:reply:",
        "listEvents:reply:",
        "listHostSettingsWithRequestID:reply:",
        "listJobsWithRequestID:reply:",
        "listOrganizationWithRequestID:reply:",
        "listProfilesWithRequestID:reply:",
        "pullJobChanges:reply:",
        "setBoolSetting:reply:",
        "setDefaultDestination:reply:",
        "setJobCategory:reply:",
        "setJobFilename:reply:",
        "setJobPriority:reply:",
        "setJobProject:reply:",
        "setJobTags:reply:",
        "upsertBandwidthPolicy:reply:",
        "upsertCategoryRule:reply:",
        "upsertCookieProfile:reply:",
        "upsertCredentialProfile:reply:",
        "upsertHostSetting:reply:",
        "upsertProject:reply:",
        "upsertProxyProfile:reply:",
        "upsertTag:reply:"
    ]

    private func protocolSelectors() throws -> [String] {
        let proto = try XCTUnwrap(
            objc_getProtocol("DMEngineControlProtocol"),
            "EngineControlProtocol must keep its @objc(DMEngineControlProtocol) name — "
                + "the XPC interface is built from it"
        )
        var count: UInt32 = 0
        guard let list = protocol_copyMethodDescriptionList(proto, true, true, &count) else {
            return []
        }
        defer { free(list) }
        return (0 ..< Int(count)).compactMap { index in
            list[index].name.map { NSStringFromSelector($0) }
        }.sorted()
    }

    func testProtocolSelectorsMatchTheCheckedInList() throws {
        let actual = try protocolSelectors()
        let expected = Self.expectedSelectors.sorted()
        let added = Set(actual).subtracting(expected).sorted()
        let removed = Set(expected).subtracting(actual).sorted()
        XCTAssertTrue(
            added.isEmpty && removed.isEmpty,
            """
            EngineControlProtocol drifted from the checked-in selector list.
            added:   \(added)
            removed: \(removed)
            Update XPCContractDriftTests.expectedSelectors — and while you are there,
            confirm the RPC also landed in EngineControlInterface.swift,
            EngineService.swift, EngineClient.swift, and ClientHello.capabilities.
            """
        )
    }

    /// Every RPC replies; a fire-and-forget method would silently drop errors.
    func testEveryRPCTakesAReplyBlock() throws {
        for selector in try protocolSelectors() {
            XCTAssertTrue(
                selector.hasSuffix("reply:"),
                "\(selector) has no reply block, so its caller cannot observe failure"
            )
        }
    }
}
