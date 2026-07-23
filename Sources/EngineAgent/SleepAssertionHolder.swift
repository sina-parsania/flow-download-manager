// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Holds a process-level idle-sleep assertion while a transfer is active.
public protocol SleepAssertionHolding: Sendable {
    /// Begin asserting; returns an opaque token to pass to ``endTransferAssertion(_:)``.
    func beginTransferAssertion(reason: String) -> AnyObject?
    /// End a previously begun assertion. No-op when `token` is nil.
    func endTransferAssertion(_ token: AnyObject?)
}

/// Test double that never touches `ProcessInfo`.
public final class NoOpSleepAssertionHolder: SleepAssertionHolding, @unchecked Sendable {
    public private(set) var beginCount = 0
    public private(set) var endCount = 0
    private let lock = NSLock()

    public init() {}

    public func beginTransferAssertion(reason: String) -> AnyObject? {
        _ = reason
        lock.lock()
        beginCount += 1
        lock.unlock()
        return NSObject()
    }

    public func endTransferAssertion(_ token: AnyObject?) {
        guard token != nil else { return }
        lock.lock()
        endCount += 1
        lock.unlock()
    }
}

/// Production holder using `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`.
public final class ProcessInfoSleepAssertionHolder: SleepAssertionHolding, @unchecked Sendable {
    public init() {}

    public func beginTransferAssertion(reason: String) -> AnyObject? {
        ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: reason
        ) as AnyObject
    }

    public func endTransferAssertion(_ token: AnyObject?) {
        guard let activity = token as? NSObjectProtocol else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }
}
