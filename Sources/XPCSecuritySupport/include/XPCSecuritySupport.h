// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the audit token of an @c NSXPCConnection peer.
///
/// @c NSXPCConnection declares @c -auditToken in Foundation but does not surface
/// it in the Swift interface. Reading it is the race-free, Apple-documented
/// (Quinn "The Eskimo!") mechanism for validating an XPC peer's code signature
/// via @c SecCodeCopyGuestWithAttributes ; @c -processIdentifier is subject to
/// PID reuse and is therefore not used for authorization. This shim isolates the
/// single point of contact with that property so it is auditable in one place.
/// Direct (Developer ID) distribution only. See @c Documentation/adr/0003 .
audit_token_t DMAuditTokenForXPCConnection(NSXPCConnection *connection)
    NS_SWIFT_NAME(auditToken(for:));

NS_ASSUME_NONNULL_END
