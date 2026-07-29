// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Capability token advertised in ``ServerHello/capabilities`` for change-aware
/// Library delivery. Clients without it keep polling ``listJobs``.
public enum EngineCapability {
    public static let jobChanges = "jobChanges"
}

/// Request a coalesced delta since a previously observed Library sequence.
@objc(DMPullJobChangesRequest)
public final class PullJobChangesRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    /// Last sequence the client successfully applied (`0` means “never”).
    public let sinceSequence: Int64

    public init(requestID: String, sinceSequence: Int64) {
        self.requestID = requestID
        self.sinceSequence = sinceSequence
    }

    public required init?(coder: NSCoder) {
        guard let requestID = coder.decodeUUIDString("requestID") else { return nil }
        self.requestID = requestID
        sinceSequence = coder.decodeInt64(forKey: "sinceSequence")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(sinceSequence, forKey: "sinceSequence")
    }
}

/// Coalesced Library delta. When ``hasGap`` is true the client must call
/// ``EngineControlProtocol/listJobs(requestID:reply:)`` and replace local state.
@objc(DMJobChangeBatch)
public final class JobChangeBatch: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let sequence: Int64
    public let sinceSequence: Int64
    public let upserts: [JobSnapshot]
    public let removedJobIDs: [String]
    public let hasGap: Bool

    public init(
        requestID: String,
        sequence: Int64,
        sinceSequence: Int64,
        upserts: [JobSnapshot],
        removedJobIDs: [String],
        hasGap: Bool
    ) {
        self.requestID = requestID
        self.sequence = sequence
        self.sinceSequence = sinceSequence
        self.upserts = upserts
        self.removedJobIDs = removedJobIDs
        self.hasGap = hasGap
    }

    public required init?(coder: NSCoder) {
        let upserts = coder.decodeArrayOfObjects(ofClass: JobSnapshot.self, forKey: "upserts") ?? []
        let removed = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "removedJobIDs") ?? []
        guard let requestID = coder.decodeUUIDString("requestID") else { return nil }
        // Removals drive deletion of local rows, so a malformed identifier fails
        // the whole batch rather than being skipped past.
        guard removed.count <= EngineXPC.maxCollectionCount,
              removed.allSatisfy({ UUID(uuidString: $0 as String) != nil })
        else { return nil }
        self.requestID = requestID
        sequence = coder.decodeInt64(forKey: "sequence")
        sinceSequence = coder.decodeInt64(forKey: "sinceSequence")
        self.upserts = upserts
        removedJobIDs = removed.map { $0 as String }
        hasGap = coder.decodeBool(forKey: "hasGap")
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(sequence, forKey: "sequence")
        coder.encode(sinceSequence, forKey: "sinceSequence")
        coder.encode(upserts as NSArray, forKey: "upserts")
        coder.encode(removedJobIDs as NSArray, forKey: "removedJobIDs")
        coder.encode(hasGap, forKey: "hasGap")
    }
}
