// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
import XPCContracts

/// Secure-coding round-trips and size-limit enforcement for the XPC DTOs
/// (`04-domain-and-data-contracts.md` §9). These also cover the `@unchecked
/// Sendable` DTOs' encode/decode invariant referenced in their declarations.
final class XPCCodingTests: XCTestCase {
    private func roundTrip<T: NSObject & NSSecureCoding>(_ value: T, as type: T.Type) throws -> T? {
        let data = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        let decoded = unarchiver.decodeObject(of: type, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        return decoded
    }

    func testClientHelloRoundTrip() throws {
        let hello = ClientHello(
            protocolVersion: 1,
            clientBuild: "42",
            clientRole: .nativeHost,
            capabilities: ["a", "b"]
        )
        let decoded = try roundTrip(hello, as: ClientHello.self)
        XCTAssertEqual(decoded?.protocolVersion, 1)
        XCTAssertEqual(decoded?.clientBuild, "42")
        XCTAssertEqual(decoded?.clientRole, .nativeHost)
        XCTAssertEqual(decoded?.capabilities, ["a", "b"])
    }

    func testServerHelloRoundTrip() throws {
        let hello = ServerHello(acceptedVersion: 1, engineBuild: "0.1.0", databaseVersion: 1, capabilities: ["health"])
        let decoded = try roundTrip(hello, as: ServerHello.self)
        XCTAssertEqual(decoded?.acceptedVersion, 1)
        XCTAssertEqual(decoded?.engineBuild, "0.1.0")
        XCTAssertEqual(decoded?.databaseVersion, 1)
        XCTAssertEqual(decoded?.capabilities, ["health"])
    }

    func testHealthSnapshotRoundTrip() throws {
        let snapshot = EngineHealthSnapshot(
            requestID: UUID().uuidString, engineBuild: "0.1.0",
            databaseVersion: 1, databaseOpen: true, uptimeSeconds: 12.5
        )
        let decoded = try roundTrip(snapshot, as: EngineHealthSnapshot.self)
        XCTAssertEqual(decoded?.databaseOpen, true)
        XCTAssertEqual(decoded?.uptimeSeconds, 12.5)
    }

    func testOversizedStringRejectedByDecoder() throws {
        let oversized = ClientHello(
            protocolVersion: 1,
            clientBuild: String(repeating: "A", count: EngineXPC.maxPayloadStringLength + 1),
            clientRole: .app, capabilities: []
        )
        let decoded = try roundTrip(oversized, as: ClientHello.self)
        XCTAssertNil(decoded, "clientBuild exceeding the size cap must fail secure decoding")
    }

    func testOversizedCapabilityElementRejectedByDecoder() throws {
        // A single over-long capability string must fail decoding even though the
        // collection count is within bounds.
        let longElement = String(repeating: "A", count: EngineXPC.maxPayloadStringLength + 1)
        let oversized = ClientHello(protocolVersion: 1, clientBuild: "x", clientRole: .app, capabilities: [longElement])
        let decoded = try roundTrip(oversized, as: ClientHello.self)
        XCTAssertNil(decoded, "an over-long capability element must fail secure decoding")
    }

    func testOversizedCollectionRejectedByDecoder() throws {
        let manyCaps = (0 ... EngineXPC.maxCollectionCount).map { "cap\($0)" }
        let oversized = ClientHello(protocolVersion: 1, clientBuild: "x", clientRole: .app, capabilities: manyCaps)
        let decoded = try roundTrip(oversized, as: ClientHello.self)
        XCTAssertNil(decoded, "capabilities exceeding the count cap must fail secure decoding")
    }

    func testEnqueueBatchRequestOptionalFieldsRoundTrip() throws {
        let cred = UUID().uuidString
        let proxy = UUID().uuidString
        let project = UUID().uuidString
        let request = EnqueueBatchRequest(
            requestID: UUID().uuidString,
            source: "paste",
            displayName: "Batch",
            items: [BatchURLItem(url: "https://example.test/a.mp4", categoryStableKey: "videos")],
            credentialProfileID: cred,
            proxyProfileID: proxy,
            cookieProfileID: nil,
            customHeadersJSON: #"[{"name":"X-Test","value":"1"}]"#,
            projectID: project,
            scheduleStartAtISO8601: "2026-07-23T12:00:00Z"
        )
        let decoded = try roundTrip(request, as: EnqueueBatchRequest.self)
        XCTAssertEqual(decoded?.credentialProfileID, cred)
        XCTAssertEqual(decoded?.proxyProfileID, proxy)
        XCTAssertNil(decoded?.cookieProfileID)
        XCTAssertEqual(decoded?.customHeadersJSON, #"[{"name":"X-Test","value":"1"}]"#)
        XCTAssertEqual(decoded?.projectID, project)
        XCTAssertEqual(decoded?.scheduleStartAtISO8601, "2026-07-23T12:00:00Z")
        XCTAssertEqual(decoded?.items.count, 1)
    }

    func testEnqueueBatchRequestNilOptionalFieldsCompatible() throws {
        let legacy = EnqueueBatchRequest(
            requestID: UUID().uuidString,
            source: "paste",
            displayName: nil,
            items: [BatchURLItem(url: "https://example.test/a.bin", categoryStableKey: "other")]
        )
        let decoded = try roundTrip(legacy, as: EnqueueBatchRequest.self)
        XCTAssertNil(decoded?.credentialProfileID)
        XCTAssertNil(decoded?.proxyProfileID)
        XCTAssertNil(decoded?.cookieProfileID)
        XCTAssertNil(decoded?.customHeadersJSON)
        XCTAssertNil(decoded?.projectID)
        XCTAssertNil(decoded?.scheduleStartAtISO8601)
    }

    func testCategoryRuleSnapshotRoundTrip() throws {
        let snapshot = CategoryRuleSnapshot(
            id: UUID().uuidString,
            priority: 2,
            enabled: true,
            predicateJSON: #"{"extension":"mp4"}"#,
            categoryStableKey: "documents"
        )
        let decoded = try roundTrip(snapshot, as: CategoryRuleSnapshot.self)
        XCTAssertEqual(decoded?.priority, 2)
        XCTAssertEqual(decoded?.enabled, true)
        XCTAssertEqual(decoded?.categoryStableKey, "documents")
        XCTAssertEqual(decoded?.predicateJSON, #"{"extension":"mp4"}"#)
    }
}
