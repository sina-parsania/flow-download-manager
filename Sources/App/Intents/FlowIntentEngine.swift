// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import Foundation
import Presentation
import SharedObservability
import XPCContracts

/// One download as an intent sees it.
///
/// A value type so it can leave the main actor, where the engine connection lives,
/// and be handed to `perform()` without carrying anything mutable with it.
struct DownloadIntentSnapshot: Sendable, Equatable {
    let id: String
    let name: String
    let state: JobState
    let link: String
    let percentComplete: Int
    let bytesReceived: Int

    /// The only wording for a state that ever reaches a person. The raw
    /// persistence token stops at `JobState(rawValue:)` inside the gateway.
    var status: String {
        state.displayName
    }
}

/// A queued download plus whether the requested save name could be applied.
struct AddedDownload: Sendable, Equatable {
    let download: DownloadIntentSnapshot
    let fileNameApplied: Bool
}

/// The single door between App Intents and the download engine.
///
/// `EngineClient` is main-actor isolated and owns the app's only connection to the
/// engine; App Intents calls `perform()` from a non-isolated async context. Rather
/// than smuggling the client across that boundary, every entry point here is
/// `@MainActor` and returns `Sendable` value types — the hop happens once, at the
/// call, and the intents themselves need no isolation annotations at all.
///
/// Intents go through the same XPC client as the rest of the app on purpose: the
/// UI never owns sockets, partial files or the queue, and a shortcut is just
/// another caller of the same commands.
@MainActor
enum FlowIntentEngine {
    /// Source recorded on the batch so a download added by a shortcut is
    /// distinguishable from one pasted into the Add sheet.
    private static let batchSource = "shortcut"

    private static let client = EngineClient()

    /// One transport heal per app lifetime. After the client has been pointed at
    /// the bundled engine service it stays there, and `EngineClient` does its own
    /// reconnect, so a second failure means the engine really is not answering.
    private static var didHealTransport = false

    // MARK: - Commands

    /// Queues one link and reports the job the engine created for it.
    static func add(_ request: ValidatedDownload) async throws -> AddedDownload {
        let jobIDs = try await enqueue([request])
        guard let jobID = jobIDs.first else { throw FlowIntentFailure.addFailed }

        var fileNameApplied = true
        if let fileName = request.fileName {
            do {
                _ = try await client.setJobFilename(jobID: jobID, filename: fileName)
            } catch {
                // The download is queued either way — the name is the only
                // casualty, and the intent's reply says so rather than pretending.
                fileNameApplied = false
                EngineLog.app.error(
                    "intent could not apply file name: \(EngineLog.redacted(error), privacy: .public)"
                )
            }
        }

        let byID = try await downloadsByID()
        let download = byID[jobID] ?? placeholder(jobID: jobID, request: request)
        return AddedDownload(download: download, fileNameApplied: fileNameApplied)
    }

    /// Queues several links in one batch and reports the jobs created for them.
    static func add(_ requests: [ValidatedDownload]) async throws -> [DownloadIntentSnapshot] {
        let jobIDs = try await enqueue(requests)
        let byID = try await downloadsByID()
        return zip(jobIDs, requests).map { jobID, request in
            byID[jobID] ?? placeholder(jobID: jobID, request: request)
        }
    }

    /// Pauses everything that can be paused. Returns how many were paused.
    static func pauseAll() async throws -> Int {
        try await applyToAll(command: .pause, shouldReceive: BulkJobCommandFilter.shouldReceivePause)
    }

    /// Resumes everything that is paused. Returns how many were resumed.
    static func resumeAll() async throws -> Int {
        try await applyToAll(command: .resume, shouldReceive: BulkJobCommandFilter.shouldReceiveResume)
    }

    /// The current library, newest engine ordering preserved.
    static func downloads() async throws -> [DownloadIntentSnapshot] {
        let snapshot = try await run { client in
            try await client.listJobs()
        }
        return snapshot.jobs.compactMap { makeSnapshot($0) }
    }

    // MARK: - Private

    private static func enqueue(_ requests: [ValidatedDownload]) async throws -> [String] {
        let items = requests.map { request -> (url: String, categoryStableKey: String) in
            let classified = ClassificationEngine.classify(
                filenameEvidence: request.fileName,
                mimeEvidence: nil,
                urlPath: request.link,
                rules: nil
            )
            return (request.link, classified.stableKey)
        }
        let response = try await run { client in
            try await client.enqueueBatch(source: batchSource, displayName: nil, items: items)
        }
        guard !response.jobIDs.isEmpty else { throw FlowIntentFailure.addFailed }
        return response.jobIDs
    }

    private static func applyToAll(
        command: JobCommandKind,
        shouldReceive: (JobState) -> Bool
    ) async throws -> Int {
        let snapshot = try await run { client in
            try await client.listJobs()
        }
        var targets = 0
        var changed = 0
        for job in snapshot.jobs {
            guard let state = JobState(rawValue: job.state), shouldReceive(state) else { continue }
            targets += 1
            do {
                _ = try await client.controlJob(jobID: job.id, command: command)
                changed += 1
            } catch {
                EngineLog.app.error(
                    "intent bulk command failed for one job: \(EngineLog.redacted(error), privacy: .public)"
                )
            }
        }
        // Nothing to do is a fine outcome; asking for many and achieving none is not.
        guard targets == 0 || changed > 0 else { throw FlowIntentFailure.updateFailed }
        return changed
    }

    private static func downloadsByID() async throws -> [String: DownloadIntentSnapshot] {
        let all = try await downloads()
        return Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func makeSnapshot(_ job: JobSnapshot) -> DownloadIntentSnapshot? {
        // A row whose state does not parse is dropped rather than surfaced with a
        // raw identifier: `displayName` is the only state wording a person sees.
        guard let state = JobState(rawValue: job.state) else { return nil }
        let percent = job.hasProgress
            ? min(100, max(0, Int((job.progressFraction * 100).rounded())))
            : 0
        return DownloadIntentSnapshot(
            id: job.id,
            name: job.name,
            state: state,
            link: job.sourceURL,
            percentComplete: percent,
            bytesReceived: Int(job.bytesTransferred)
        )
    }

    /// Describes a job the engine has just written but the follow-up read missed.
    ///
    /// `queued` is not a guess: a batch with no schedule is inserted in exactly
    /// that state, and the insert has already committed by the time the reply
    /// carrying this job's identifier came back.
    private static func placeholder(jobID: String, request: ValidatedDownload) -> DownloadIntentSnapshot {
        let derivedName = request.fileName
            ?? URL(string: request.link)?.lastPathComponent
            ?? request.link
        return DownloadIntentSnapshot(
            id: jobID,
            name: derivedName.isEmpty ? request.link : derivedName,
            state: .queued,
            link: request.link,
            percentComplete: 0,
            bytesReceived: 0
        )
    }

    /// Runs an engine call, healing onto the bundled engine service once before
    /// giving up.
    ///
    /// A shortcut can fire when the app has never been opened this session, so the
    /// engine genuinely may not be running. Everything the connection can report is
    /// collapsed into one plain sentence here — the transport never reaches a
    /// person, only the log.
    private static func run<T>(_ body: (EngineClient) async throws -> T) async throws -> T {
        do {
            return try await body(client)
        } catch {
            EngineLog.app.error(
                "intent engine call failed: \(EngineLog.redacted(error), privacy: .public)"
            )
        }

        guard !didHealTransport else { throw FlowIntentFailure.engineUnavailable }
        didHealTransport = true

        do {
            try DirectAgentHost.shared.ensureTransport()
        } catch {
            EngineLog.app.error(
                "intent engine transport unavailable: \(EngineLog.redacted(error), privacy: .public)"
            )
            throw FlowIntentFailure.engineUnavailable
        }
        client.useBundledXPCService()

        do {
            return try await body(client)
        } catch {
            EngineLog.app.error(
                "intent engine retry failed: \(EngineLog.redacted(error), privacy: .public)"
            )
            throw FlowIntentFailure.engineUnavailable
        }
    }
}
