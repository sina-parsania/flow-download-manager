// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Immutable read snapshot for one row of the download table. Presentation
/// consumes read snapshots and submits commands; it never reads persistence
/// directly (`02-architecture.md` §4.5). In later phases these are delivered over
/// XPC; in Phase 0 they come from deterministic fixtures.
public struct JobRowModel: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let sourceHost: String
    public let state: JobState
    /// 0...1 completion fraction, or nil when unknown (indeterminate).
    public let progressFraction: Double?
    public let bytesTransferred: Int64
    public let totalBytes: Int64?
    public let speedBytesPerSecond: Int64
    public let etaSeconds: Int?
    public let categoryKey: String
    public let projectName: String?
    public let tagNames: [String]
    public let priority: Int

    public init(
        id: UUID, name: String, sourceHost: String, state: JobState,
        progressFraction: Double?, bytesTransferred: Int64, totalBytes: Int64?,
        speedBytesPerSecond: Int64, etaSeconds: Int?, categoryKey: String,
        projectName: String?, tagNames: [String], priority: Int = 0
    ) {
        self.id = id
        self.name = name
        self.sourceHost = sourceHost
        self.state = state
        self.progressFraction = progressFraction
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.etaSeconds = etaSeconds
        self.categoryKey = categoryKey
        self.projectName = projectName
        self.tagNames = tagNames
        self.priority = priority
    }

    /// A stable status role used to pick supplemental colour/symbol (colour is
    /// never the only signal — `03-design-system-ui-ux.md` §10).
    public var statusRole: StatusRole {
        switch state {
        case .downloading, .connecting, .verifying, .merging, .postProcessing: return .active
        case .queued, .scheduled, .ready, .created, .inspecting, .awaitingUserSelection: return .queued
        case .paused, .retryWaiting: return .paused
        case .completed: return .success
        case .failed: return .failure
        case .cancelled: return .paused
        }
    }

    public enum StatusRole: Sendable { case active, queued, paused, success, failure }
}
