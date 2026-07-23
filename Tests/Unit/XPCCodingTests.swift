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

    func testEventSnapshotRoundTrip() throws {
        let jobID = UUID().uuidString
        let snapshot = EventSnapshot(
            sequence: 42,
            jobID: jobID,
            occurredAtISO8601: "2026-07-23T08:00:00Z",
            type: "state.changed",
            sanitizedPayload: #"{"state":"queued"}"#
        )
        let decoded = try roundTrip(snapshot, as: EventSnapshot.self)
        XCTAssertEqual(decoded?.sequence, 42)
        XCTAssertEqual(decoded?.jobID, jobID)
        XCTAssertEqual(decoded?.type, "state.changed")
        XCTAssertEqual(decoded?.sanitizedPayload, #"{"state":"queued"}"#)
    }

    func testClearEventsDTORoundTrip() throws {
        let request = ClearEventsRequest(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString
        )
        let decodedRequest = try roundTrip(request, as: ClearEventsRequest.self)
        XCTAssertEqual(decodedRequest?.jobID, request.jobID)

        let response = ClearEventsResponse(requestID: UUID().uuidString, deletedCount: 7)
        let decodedResponse = try roundTrip(response, as: ClearEventsResponse.self)
        XCTAssertEqual(decodedResponse?.deletedCount, 7)
    }

    func testCookieAndBandwidthDTORoundTrip() throws {
        let cookie = CookieProfileSnapshot(id: UUID().uuidString, displayName: "Browser")
        let decodedCookie = try roundTrip(cookie, as: CookieProfileSnapshot.self)
        XCTAssertEqual(decodedCookie?.displayName, "Browser")

        let policy = BandwidthPolicySnapshot(
            id: "00000000-0000-7000-8000-0000000000b1",
            name: "Global",
            windowsJSON: #"[]"#,
            maxBytesPerSecond: 1_000_000
        )
        let decodedPolicy = try roundTrip(policy, as: BandwidthPolicySnapshot.self)
        XCTAssertEqual(decodedPolicy?.maxBytesPerSecond, 1_000_000)

        let list = ListProfilesResponse(
            requestID: UUID().uuidString,
            credentials: [],
            proxies: [],
            cookies: [cookie]
        )
        let decodedList = try roundTrip(list, as: ListProfilesResponse.self)
        XCTAssertEqual(decodedList?.cookies.count, 1)
        XCTAssertEqual(decodedList?.cookies.first?.displayName, "Browser")
    }

    func testSetJobPriorityDTORoundTrip() throws {
        let request = SetJobPriorityRequest(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            priority: 7
        )
        let decodedRequest = try roundTrip(request, as: SetJobPriorityRequest.self)
        XCTAssertEqual(decodedRequest?.priority, 7)

        let response = SetJobPriorityResponse(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            priority: 7,
            revision: 3
        )
        let decodedResponse = try roundTrip(response, as: SetJobPriorityResponse.self)
        XCTAssertEqual(decodedResponse?.priority, 7)
        XCTAssertEqual(decodedResponse?.revision, 3)

        let snapshot = JobSnapshot(
            id: UUID().uuidString,
            name: "a.bin",
            sourceHost: "cdn.example.test",
            sourceURL: "https://cdn.example.test/a.bin",
            state: "queued",
            progressFraction: nil,
            bytesTransferred: 0,
            totalBytes: nil,
            speedBytesPerSecond: 0,
            categoryKey: "other",
            priority: 4
        )
        let decodedSnapshot = try roundTrip(snapshot, as: JobSnapshot.self)
        XCTAssertEqual(decodedSnapshot?.priority, 4)
        XCTAssertEqual(decodedSnapshot?.sourceURL, "https://cdn.example.test/a.bin")
    }

    func testDeleteJobDTORoundTrip() throws {
        let request = DeleteJobRequest(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            deleteFiles: true
        )
        let decodedRequest = try roundTrip(request, as: DeleteJobRequest.self)
        XCTAssertEqual(decodedRequest?.jobID, request.jobID)
        XCTAssertEqual(decodedRequest?.deleteFiles, true)

        let libraryOnly = DeleteJobRequest(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString
        )
        let decodedLibraryOnly = try roundTrip(libraryOnly, as: DeleteJobRequest.self)
        XCTAssertEqual(decodedLibraryOnly?.deleteFiles, false)

        let response = DeleteJobResponse(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            previousState: "failed"
        )
        let decodedResponse = try roundTrip(response, as: DeleteJobResponse.self)
        XCTAssertEqual(decodedResponse?.previousState, "failed")
    }

    func testJobCommandRestartRoundTrip() throws {
        let request = JobCommandRequest(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            command: .restart,
            expectedRevision: 2
        )
        let decoded = try roundTrip(request, as: JobCommandRequest.self)
        XCTAssertEqual(decoded?.command, .restart)
        XCTAssertEqual(decoded?.command.rawValue, 5)
        XCTAssertEqual(decoded?.expectedRevision, 2)
    }

    func testSetJobProjectAndBoolSettingRoundTrip() throws {
        let projectRequest = SetJobProjectRequest(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            projectID: UUID().uuidString
        )
        let decodedProject = try roundTrip(projectRequest, as: SetJobProjectRequest.self)
        XCTAssertEqual(decodedProject?.projectID, projectRequest.projectID)

        let clearRequest = SetJobProjectRequest(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            projectID: nil
        )
        let decodedClear = try roundTrip(clearRequest, as: SetJobProjectRequest.self)
        XCTAssertNil(decodedClear?.projectID)

        let categoryRequest = SetJobCategoryRequest(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            categoryStableKey: "videos"
        )
        let decodedCategory = try roundTrip(categoryRequest, as: SetJobCategoryRequest.self)
        XCTAssertEqual(decodedCategory?.categoryStableKey, "videos")

        let categoryResponse = SetJobCategoryResponse(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            categoryStableKey: "audio"
        )
        let decodedCategoryResponse = try roundTrip(categoryResponse, as: SetJobCategoryResponse.self)
        XCTAssertEqual(decodedCategoryResponse?.categoryStableKey, "audio")

        let getRequest = GetBoolSettingRequest(
            requestID: UUID().uuidString,
            key: "zipAutoExtractEnabled"
        )
        let decodedGet = try roundTrip(getRequest, as: GetBoolSettingRequest.self)
        XCTAssertEqual(decodedGet?.key, "zipAutoExtractEnabled")

        let getResponse = GetBoolSettingResponse(
            requestID: UUID().uuidString,
            key: "zipAutoExtractEnabled",
            value: true
        )
        let decodedGetResponse = try roundTrip(getResponse, as: GetBoolSettingResponse.self)
        XCTAssertEqual(decodedGetResponse?.value, true)

        let setRequest = SetBoolSettingRequest(
            requestID: UUID().uuidString,
            key: "zipAutoExtractEnabled",
            value: false
        )
        let decodedSet = try roundTrip(setRequest, as: SetBoolSettingRequest.self)
        XCTAssertEqual(decodedSet?.value, false)

        let snapshot = JobSnapshot(
            id: UUID().uuidString,
            name: "a.zip",
            sourceHost: "cdn.example.test",
            sourceURL: "https://cdn.example.test/a.zip",
            state: "queued",
            progressFraction: 0.5,
            bytesTransferred: 10,
            totalBytes: 20,
            speedBytesPerSecond: 1,
            categoryKey: "archives",
            projectID: UUID().uuidString,
            projectName: "Film",
            tagIDs: [UUID().uuidString],
            tagNames: ["urgent"],
            priority: 1
        )
        let decodedSnapshot = try roundTrip(snapshot, as: JobSnapshot.self)
        XCTAssertEqual(decodedSnapshot?.projectID, snapshot.projectID)
        XCTAssertEqual(decodedSnapshot?.tagIDs, snapshot.tagIDs)
        XCTAssertEqual(decodedSnapshot?.tagNames, ["urgent"])
        XCTAssertEqual(decodedSnapshot?.sourceURL, "https://cdn.example.test/a.zip")

        let renameRequest = SetJobFilenameRequest(
            requestID: UUID().uuidString,
            jobID: UUID().uuidString,
            filename: "renamed.zip"
        )
        let decodedRename = try roundTrip(renameRequest, as: SetJobFilenameRequest.self)
        XCTAssertEqual(decodedRename?.filename, "renamed.zip")
    }
}
