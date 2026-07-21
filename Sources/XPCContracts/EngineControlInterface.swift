// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Builds the `NSXPCInterface` for ``EngineControlProtocol`` with the exact
/// allowlist of decodable classes for every argument and reply.
///
/// No arbitrary object decoding is permitted (`02-architecture.md` §10): each
/// method whitelists only the concrete secure-coding DTO plus the plist scalar
/// classes it composes. Both the agent (exported interface) and the app (remote
/// interface) build the interface the same way so the class allowlist is single-
/// sourced.
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
        return interface
    }

    /// Bridge a static, known-good list of classes to the `Set<AnyHashable>` the
    /// XPC API expects without a forced cast. The list is a compile-time constant,
    /// so the bridge cannot realistically fail; an empty fallback keeps the code
    /// total.
    private static func allowedClasses(_ classes: [AnyClass]) -> Set<AnyHashable> {
        (NSSet(array: classes) as? Set<AnyHashable>) ?? []
    }
}
