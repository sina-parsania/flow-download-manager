// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Builds the `NSXPCInterface` for ``EngineControlProtocol`` with the exact
/// allowlist of decodable classes for every argument and reply.
public enum EngineControlInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: EngineControlProtocol.self)

        interface.setClasses(
            allowedClasses([ClientHello.self, NSString.self, NSArray.self]),
            for: #selector(EngineControlProtocol.handshake(_:reply:)),
            argumentIndex: 0, ofReply: false
        )
        interface.setClasses(
            allowedClasses([ServerHello.self, NSString.self, NSArray.self]),
            for: #selector(EngineControlProtocol.handshake(_:reply:)),
            argumentIndex: 0, ofReply: true
        )
        interface.setClasses(
            allowedClasses([EngineHealthSnapshot.self, NSString.self]),
            for: #selector(EngineControlProtocol.healthStatus(requestID:reply:)),
            argumentIndex: 0, ofReply: true
        )

        interface.setClasses(
            allowedClasses([
                EnqueueBatchRequest.self, BatchURLItem.self, NSString.self, NSArray.self
            ]),
            for: #selector(EngineControlProtocol.enqueueBatch(_:reply:)),
            argumentIndex: 0, ofReply: false
        )
        interface.setClasses(
            allowedClasses([EnqueueBatchResponse.self, NSString.self, NSArray.self]),
            for: #selector(EngineControlProtocol.enqueueBatch(_:reply:)),
            argumentIndex: 0, ofReply: true
        )

        interface.setClasses(
            allowedClasses([JobListSnapshot.self, JobSnapshot.self, NSString.self, NSArray.self]),
            for: #selector(EngineControlProtocol.listJobs(requestID:reply:)),
            argumentIndex: 0, ofReply: true
        )

        interface.setClasses(
            allowedClasses([JobCommandRequest.self, NSString.self]),
            for: #selector(EngineControlProtocol.controlJob(_:reply:)),
            argumentIndex: 0, ofReply: false
        )
        interface.setClasses(
            allowedClasses([JobCommandResponse.self, NSString.self]),
            for: #selector(EngineControlProtocol.controlJob(_:reply:)),
            argumentIndex: 0, ofReply: true
        )

        interface.setClasses(
            allowedClasses([
                UpsertCredentialProfileRequest.self, NSString.self, NSData.self
            ]),
            for: #selector(EngineControlProtocol.upsertCredentialProfile(_:reply:)),
            argumentIndex: 0, ofReply: false
        )
        interface.setClasses(
            allowedClasses([UpsertCredentialProfileResponse.self, NSString.self]),
            for: #selector(EngineControlProtocol.upsertCredentialProfile(_:reply:)),
            argumentIndex: 0, ofReply: true
        )

        interface.setClasses(
            allowedClasses([UpsertProxyProfileRequest.self, NSString.self]),
            for: #selector(EngineControlProtocol.upsertProxyProfile(_:reply:)),
            argumentIndex: 0, ofReply: false
        )
        interface.setClasses(
            allowedClasses([UpsertProxyProfileResponse.self, NSString.self]),
            for: #selector(EngineControlProtocol.upsertProxyProfile(_:reply:)),
            argumentIndex: 0, ofReply: true
        )

        interface.setClasses(
            allowedClasses([
                ListProfilesResponse.self,
                CredentialProfileSnapshot.self,
                ProxyProfileSnapshot.self,
                NSString.self,
                NSArray.self
            ]),
            for: #selector(EngineControlProtocol.listProfiles(requestID:reply:)),
            argumentIndex: 0, ofReply: true
        )
        return interface
    }

    private static func allowedClasses(_ classes: [AnyClass]) -> Set<AnyHashable> {
        (NSSet(array: classes) as? Set<AnyHashable>) ?? []
    }
}
