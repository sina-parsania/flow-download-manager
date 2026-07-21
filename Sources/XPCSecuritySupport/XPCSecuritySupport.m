// SPDX-License-Identifier: GPL-3.0-or-later
#import "XPCSecuritySupport.h"

// -auditToken is declared by Foundation on NSXPCConnection but is absent from the
// generated Swift interface. Re-declaring it here (not synthesizing it) lets this
// shim read the real property. Scoped to this file so the SPI touchpoint is
// contained and reviewable.
@interface NSXPCConnection (DMPrivateAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

audit_token_t DMAuditTokenForXPCConnection(NSXPCConnection *connection) {
    return connection.auditToken;
}
