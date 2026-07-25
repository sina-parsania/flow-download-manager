// SPDX-License-Identifier: GPL-3.0-or-later

import CCurl
import Foundation

/// Cooperative abort token shared with the C write/xferinfo callbacks.
/// `reset()` is only valid when no transfer concurrently holds `cToken`.
public final class TransferAbortFlag: Sendable {
    private nonisolated(unsafe) let token: OpaquePointer

    public init() {
        guard let created = DMCurlAbortFlagCreate() else {
            preconditionFailure("DMCurlAbortFlagCreate returned nil")
        }
        token = created
    }

    deinit {
        DMCurlAbortFlagDestroy(token)
    }

    /// Read-only bridge for C download APIs. Do not reset while a transfer holds this.
    public var cToken: OpaquePointer {
        token
    }

    public func requestAbort() {
        DMCurlAbortFlagRequest(token)
    }

    public var isSet: Bool {
        DMCurlAbortFlagIsSet(token) != 0
    }

    public func reset() {
        DMCurlAbortFlagReset(token)
    }
}
