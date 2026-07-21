// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Monotonically increasing integer schema versions.
///
/// Database, XPC and Native Messaging schemas version independently
/// (`00-master-plan.md` §5). Phase 0 establishes version 1 of the database and
/// the XPC protocol; the Native Messaging schema is declared for completeness but
/// has no shipping surface until Phase 2.
public enum SchemaVersions {
    /// GRDB migration identifier space. Phase 0 ships `v1`.
    public static let database = 1

    /// XPC handshake `protocolVersion`. Unknown major versions are rejected
    /// before payload decoding (`04-domain-and-data-contracts.md` §9).
    public static let xpcProtocol = 1

    /// Native Messaging envelope `protocolVersion`. Declared, not yet exposed.
    public static let nativeMessaging = 1
}
