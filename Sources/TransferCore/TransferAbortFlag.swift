// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Cooperative abort token shared with the C write/xferinfo callbacks.
public final class TransferAbortFlag: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Int32>

    public init() {
        storage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        storage.initialize(to: 0)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    public var pointer: UnsafeMutablePointer<Int32> {
        storage
    }

    public func requestAbort() {
        storage.pointee = 1
    }

    public var isSet: Bool {
        storage.pointee != 0
    }

    public func reset() {
        storage.pointee = 0
    }
}
