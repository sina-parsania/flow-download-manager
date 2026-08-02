// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import Foundation
import Persistence
import SharedObservability
import SharedSecurity
import TransferCore
import XPCContracts

/// Sockets reserved for one transfer beyond its primary connection.
///
/// Mutable and shared because the connection ramp reserves more while the
/// transfer is running, and the release path in `runJob`'s `defer` has to give
/// back the final total rather than the count it started with. Leaking here
/// permanently shrinks the host's budget for every later download.
private final class SocketGrant: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(extra: Int) {
        value = extra
    }

    var extra: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func add(_ sockets: Int) {
        guard sockets > 0 else { return }
        lock.lock()
        value += sockets
        lock.unlock()
    }
}

/// Latest cumulative byte count for one in-flight transfer.
///
/// Written from libcurl's write-callback threads and drained by the
/// orchestrator's progress ticker. Coalescing here rather than per callback is
/// what keeps actor traffic independent of link speed. `take()` returns nil
/// when nothing new has arrived, so an idle transfer costs no actor hops.
private final class LiveByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64?
    private var totalBytes: Int64?

    func record(_ value: Int64, total: Int64? = nil) {
        lock.lock()
        if value > (bytes ?? -1) { bytes = value }
        if let total, total > 0 { totalBytes = total }
        lock.unlock()
    }

    func take() -> (bytes: Int64, total: Int64?)? {
        lock.lock()
        defer {
            bytes = nil
            lock.unlock()
        }
        guard let bytes else { return nil }
        return (bytes, totalBytes)
    }
}

/// Runs queued jobs through TransferCore and finalization. Agent-owned.
public actor TransferOrchestrator {
    /// Progress drain interval. The UI polls at 500 ms while a job is live, so
    /// draining at 250 ms keeps every poll fresh without over-reporting.
    private static let progressTickNanoseconds: UInt64 = 250_000_000

    private let database: EngineDatabase
    private let budget: TransferBudgetLedger
    /// Enforces the global and per-host byte ceilings across every concurrent
    /// transfer. One instance per agent process, by design — a per-job limiter is
    /// the defect this replaces.
    private let rateLimiter = SharedRateLimiter()
    private let retryPolicy: RetryPolicy
    private let progressLedger: JobProgressLedger
    private let secretStore: any SecretStore
    private let sleepAssertionHolder: any SleepAssertionHolding
    private let applicationSupportRoot: URL
    private let log = EngineLog.agent
    private var isRunning = false
    private var cancelledJobIDs: Set<String> = []
    private var pausedJobIDs: Set<String> = []
    /// When a pause is in-flight and the user resumes, finish the abort then requeue
    /// instead of clearing the abort flag (which left transfers running while UI said queued).
    private var resumeAfterAbort: Set<String> = []
    private var abortFlags: [String: TransferAbortFlag] = [:]
    private var attemptByJob: [String: Int] = [:]
    private var sleepAssertions: [String: AnyObject] = [:]
    private var speedEstimators: [String: TransferSpeedEstimator] = [:]
    /// Live connection ramp per job, stepped from the progress ticker.
    private var connectionRamps: [String: ConnectionRamp] = [:]

    public init(
        database: EngineDatabase,
        budget: TransferBudgetLedger = TransferBudgetLedger(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        progressLedger: JobProgressLedger = JobProgressLedger(),
        secretStore: any SecretStore = KeychainSecretStore(service: EngineXPC.machServiceName),
        sleepAssertionHolder: any SleepAssertionHolding = ProcessInfoSleepAssertionHolder(),
        applicationSupportRoot: URL? = nil
    ) {
        self.database = database
        self.budget = budget
        self.retryPolicy = retryPolicy
        self.progressLedger = progressLedger
        self.secretStore = secretStore
        self.sleepAssertionHolder = sleepAssertionHolder
        if let applicationSupportRoot {
            self.applicationSupportRoot = applicationSupportRoot
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
                ?? FileManager.default.temporaryDirectory
            self.applicationSupportRoot = base.appendingPathComponent(
                EngineXPC.machServiceName,
                isDirectory: true
            )
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await self.recoverInterruptedTransfers()
            await self.pump()
        }
    }

    /// Crash / relaunch recovery: reconcile interrupted finalization, then requeue
    /// ordinary in-flight transfer states.
    private func recoverInterruptedTransfers() async {
        do {
            let outcomes = try FinalizationIntentRepository.reconcileInterruptedFinalizations(
                database: database
            )
            for outcome in outcomes {
                log.info(
                    "recovery finalization id=\(outcome.jobID, privacy: .public) action=\(String(describing: outcome.action), privacy: .public)"
                )
            }
            let ids = try JobRepository.requeueInterruptedTransfers(database: database)
            if !ids.isEmpty {
                log.info("recovery requeued count=\(ids.count, privacy: .public)")
            }
        } catch {
            log.error("recovery requeue failed: \(EngineLog.redacted(error), privacy: .public)")
        }
    }

    public func stop() {
        isRunning = false
    }

    public func requestCancel(jobID: String) {
        cancelledJobIDs.insert(jobID)
        pausedJobIDs.remove(jobID)
        resumeAfterAbort.remove(jobID)
        abortFlags[jobID]?.requestAbort()
    }

    public func requestPause(jobID: String) {
        pausedJobIDs.insert(jobID)
        resumeAfterAbort.remove(jobID)
        abortFlags[jobID]?.requestAbort()
    }

    public func requestResume(jobID: String) {
        cancelledJobIDs.remove(jobID)
        pausedJobIDs.remove(jobID)
        if abortFlags[jobID] != nil {
            // Transfer still running (often mid-pause). Keep abort asserted and
            // requeue once the in-flight call returns — do not reset the flag.
            resumeAfterAbort.insert(jobID)
            abortFlags[jobID]?.requestAbort()
        } else {
            resumeAfterAbort.remove(jobID)
        }
    }

    public func clearControl(jobID: String) {
        cancelledJobIDs.remove(jobID)
        pausedJobIDs.remove(jobID)
        // Intentionally do not reset abortFlags — that races with in-flight curl.
    }

    public func clearProgress(jobID: String) {
        progressLedger.remove(jobID)
        attemptByJob[jobID] = nil
        speedEstimators[jobID] = nil
    }

    private var runningJobIDs: Set<String> = []

    private func runJobThenRelease(_ jobID: String) async {
        await runJob(jobID)
        runningJobIDs.remove(jobID)
    }

    private func resumeFinalizationThenRelease(_ jobID: String) async {
        await resumeFinalization(jobID)
        runningJobIDs.remove(jobID)
    }

    private func pump() async {
        while isRunning {
            do {
                _ = try ProfileRepository.promoteDueScheduledJobs(database: database)
                if let policy = try ProfileRepository.fetchGlobalBandwidthPolicy(database: database) {
                    let windows = try BandwidthWindowEvaluator.parseWindowsJSON(policy.windowsJSON)
                    if !BandwidthWindowEvaluator.isActive(
                        now: Date(),
                        calendar: .current,
                        windows: windows
                    ) {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                }

                // Cap parallelism by budget — never fetch/download the whole queue at once.
                // Track in-flight Tasks separately from ledger so we do not oversubscribe
                // before tryBeginJob runs.
                let maxJobs = await budget.maxActiveJobsLimit()
                let want = max(0, maxJobs - runningJobIDs.count)
                if want > 0 {
                    let finalizationIDs = try FinalizationIntentRepository
                        .fetchJobsNeedingFinalizationResume(database: database, limit: want)
                    for jobID in finalizationIDs where !runningJobIDs.contains(jobID) {
                        runningJobIDs.insert(jobID)
                        Task {
                            await self.resumeFinalizationThenRelease(jobID)
                        }
                    }
                    let remaining = max(0, want - finalizationIDs.count)
                    if remaining > 0 {
                        let ids = try JobRepository.fetchQueuedJobIDs(
                            database: database,
                            limit: remaining
                        )
                        for jobID in ids where !runningJobIDs.contains(jobID) {
                            runningJobIDs.insert(jobID)
                            Task {
                                await self.runJobThenRelease(jobID)
                            }
                        }
                    }
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                log.error("orchestrator pump error: \(EngineLog.redacted(error), privacy: .public)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func runJob(_ jobID: String) async {
        guard await budget.tryBeginJob() else {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return
        }
        defer {
            // Detached so endJob is not stuck behind a blocking curl call on this actor.
            let budget = self.budget
            Task.detached { await budget.endJob() }
            abortFlags[jobID] = nil
            endSleepAssertion(for: jobID)
        }

        let abort = TransferAbortFlag()
        abortFlags[jobID] = abort

        do {
            let details = try JobRepository.loadJobForTransfer(database: database, id: jobID)
            guard details.state == "queued" else { return }
            if cancelledJobIDs.contains(jobID) {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: .cancelled,
                    terminalReason: "userCancelled", expectedRevision: nil
                )
                cancelledJobIDs.remove(jobID)
                progressLedger.remove(jobID)
                return
            }
            if pausedJobIDs.contains(jobID) {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: .paused,
                    terminalReason: nil, expectedRevision: nil
                )
                pausedJobIDs.remove(jobID)
                return
            }

            let host = URL(string: details.canonicalURL)?.host ?? "unknown"
            let hostSetting = try? HostSettingRepository.get(database: database, host: host)
            let preferredConnections = details.preferredConnectionCount
                ?? hostSetting?.maxConnections
            await budget.beginHostJob(host)
            // Acquire capacity before any state flip. A failed grant must leave
            // the job queued without thrashing connecting→downloading→queued.
            guard await budget.tryAcquireSocket(host: host) else {
                await budget.endHostJob(host)
                try await Task.sleep(nanoseconds: 200_000_000)
                return
            }
            // Fair-share the per-host socket ceiling across concurrent jobs to
            // the same CDN. Without this, the first job reserved up to 31 extras
            // and siblings starved at ~one connection (uneven speed in the UI).
            let fairCap = await budget.fairConnectionCap(forHost: host)
            // Where the last download from this host settled, so a queue of
            // episodes from one site does not re-pay the 30-40 s climb every time.
            // An explicit user setting still wins — this only replaces the default.
            let learnedConnections = (
                try? HostObservationRepository.get(database: database, host: host)
            )?.settledConnections
            let connectionTarget = Self.connectionTarget(
                preferredConnectionCount: preferredConnections ?? learnedConnections,
                fairHostCap: fairCap
            )
            let extraSegmentSockets = await budget.reserveSockets(
                host: host,
                upTo: max(0, connectionTarget - 1)
            )
            // Sockets reserved so far. The ramp grows this during the transfer, so
            // the release path cannot capture a copy — it has to read the final
            // count.
            let grant = SocketGrant(extra: extraSegmentSockets)
            // An explicit per-job/per-host setting is an instruction, not a
            // starting point — honour it exactly and let the ramp settle at once.
            // Otherwise the ceiling is this job's fair share of the host, which is
            // the headroom the ramp is allowed to discover.
            let rampCeiling = Self.effectiveHostMaxSegments(
                preferredConnectionCount: preferredConnections,
                socketBudget: fairCap
            )
            let concurrency = ConcurrencyTarget(1 + extraSegmentSockets)
            connectionRamps[jobID] = ConnectionRamp(
                start: 1 + extraSegmentSockets,
                ceiling: rampCeiling
            )
            let rampHost = host
            defer { connectionRamps[jobID] = nil }
            defer {
                let budget = self.budget
                let limiter = self.rateLimiter
                let hostToRelease = host
                let extra = grant.extra
                Task.detached {
                    await budget.releaseSocket(host: hostToRelease)
                    await budget.releaseSockets(host: hostToRelease, count: extra)
                    // Drop the limiter's per-host accounting only once the last
                    // job on this host is gone. Clearing it while a sibling is
                    // still transferring would reset the queue cursor and let
                    // that sibling burst past the host ceiling.
                    if await budget.endHostJob(hostToRelease) == 0 {
                        limiter.forgetHost(hostToRelease)
                    }
                }
            }

            _ = try JobRepository.updateJobState(
                database: database, id: jobID, state: .connecting,
                terminalReason: nil, expectedRevision: nil
            )
            beginSleepAssertion(for: jobID)

            let accessed = details.destinationDirectory.startAccessingSecurityScopedResource()
            defer {
                if accessed { details.destinationDirectory.stopAccessingSecurityScopedResource() }
            }

            var options = try buildDownloadOptions(from: details, hostSetting: hostSetting)
            // Publish the ceilings this job is subject to into the process-wide
            // limiter, then hand the job a reference to it. The limits are NOT
            // copied into `options.maxBytesPerSecond` — a value copied per job is
            // by construction a per-job cap, which is what let five concurrent
            // downloads each run at the full configured rate.
            // A policy read failure means "no limit known", not "unlimited
            // forever": the next job to start re-reads it.
            let globalLimit = (try? activeGlobalBandwidthLimit()).flatMap(\.self) ?? 0
            rateLimiter.setGlobalLimit(bytesPerSecond: globalLimit)
            rateLimiter.setHostLimit(host: host, bytesPerSecond: hostSetting?.maxBytesPerSecond ?? 0)
            options.rateLimiter = rateLimiter
            options.rateLimitHost = host
            // CDN links often expose the real title only via Content-Disposition /
            // Content-Type on the first probe — apply that *before* choosing the
            // on-disk name so we never land "binary.partial" for a named .mp4.
            let earlyIdentity: TransferCore.ResourceIdentity? = if RangeProbePolicy.shouldSkipProbe(
                url: details.canonicalURL,
                options: options
            ) {
                nil
            } else {
                try? await Self.probeOffActor(
                    url: details.canonicalURL,
                    options: options
                )
            }
            if cancelledJobIDs.contains(jobID) || abort.isSet && cancelledJobIDs.contains(jobID) {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: .cancelled,
                    terminalReason: "userCancelled", expectedRevision: nil
                )
                cancelledJobIDs.remove(jobID)
                progressLedger.remove(jobID)
                return
            }
            if let earlyIdentity {
                try? JobRepository.updateResourceIdentity(
                    database: database,
                    jobID: jobID,
                    finalURL: earlyIdentity.finalURL,
                    expectedSize: TransferCore.totalLength(from: earlyIdentity),
                    etag: earlyIdentity.etag,
                    mime: earlyIdentity.contentType,
                    contentDisposition: earlyIdentity.contentDisposition
                )
            }
            let filename = FilenameSanitizer.sanitize(
                FilenameSanitizer.preferredFilename(
                    contentDisposition: earlyIdentity?.contentDisposition,
                    urlString: earlyIdentity?.finalURL ?? details.canonicalURL,
                    existingEvidence: details.suggestedFilename,
                    contentType: earlyIdentity?.contentType
                )
            )
            Self.refineCategoryIfOther(
                database: database,
                jobID: jobID,
                filenameEvidence: filename,
                mimeEvidence: earlyIdentity?.contentType,
                url: details.canonicalURL
            )

            // Stamped only after the refine above, so a link that arrived as `other`
            // and turned out to be a video lands in `Videos` rather than `Other`.
            let writeDirectory: URL
            do {
                writeDirectory = try Self.resolveWriteDirectory(database: database, details: details)
            } catch {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: .failed,
                    terminalReason: "destinationUnavailable", expectedRevision: nil
                )
                EngineLog.agent.error(
                    "category folder unavailable id=\(jobID, privacy: .public) err=\(EngineLog.redacted(error), privacy: .public)"
                )
                return
            }

            let partial = writeDirectory.appendingPathComponent("\(filename).partial")
            let preferredFinal = writeDirectory.appendingPathComponent(filename)
            let conflictPolicy = DestinationConflictPolicy.parse(details.conflictPolicy)
            let destinationExists = FileManager.default.fileExists(atPath: preferredFinal.path)
            let conflictAction = DestinationConflictResolver.action(
                policy: conflictPolicy,
                destinationExists: destinationExists
            )
            let final: URL
            switch conflictAction {
            case .usePreferred, .overwrite:
                final = preferredFinal
            case .uniquify:
                final = uniquifiedURL(preferredFinal)
            case .fail:
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: .failed,
                    terminalReason: "destinationExists", expectedRevision: nil
                )
                progressLedger.remove(jobID)
                attemptByJob[jobID] = nil
                return
            }

            _ = try JobRepository.updateJobState(
                database: database, id: jobID, state: .downloading,
                terminalReason: nil, expectedRevision: nil
            )

            // libcurl calls back once per write chunk from N segment threads.
            // Spawning a Task per callback flooded this actor — the same actor
            // that runs `pump()` — with unordered work proportional to link
            // speed. Instead the callback only stores the latest byte count
            // (lock-only, no actor hop) and one ticker drains it at a fixed
            // rate, so actor traffic is bounded no matter how fast the transfer.
            let liveBytes = LiveByteCounter()
            let ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: Self.progressTickNanoseconds)
                    guard let self else { continue }
                    // Tick even when nothing arrived. `take()` returns nil on a
                    // quiet interval, and skipping the call meant the estimator
                    // was never told time had passed — so a stalled transfer kept
                    // showing whatever speed it last managed. A dead connection
                    // sits for `CURLOPT_LOW_SPEED_TIME` (10 s) before libcurl
                    // kills it and the map loop can then back off up to 30 s,
                    // which is a long time to display a number that is a lie.
                    await tickProgress(jobID: jobID, sample: liveBytes.take())
                    // Same tick decides whether this transfer has earned another
                    // connection. Reserving lives here because the budget is
                    // actor state — the transfer thread cannot await it.
                    await stepConnectionRamp(
                        jobID: jobID,
                        host: rampHost,
                        grant: grant,
                        target: concurrency
                    )
                }
            }
            defer { ticker.cancel() }

            let outcome = try await Self.downloadOffActor(
                url: details.canonicalURL,
                partialURL: partial,
                options: options,
                abortFlag: abort,
                // The ceiling the ramp may grow into — NOT what is reserved. Only
                // `concurrency` says how many may actually run, and it is raised
                // solely after the matching sockets have been granted.
                hostMaxSegments: rampCeiling,
                desiredConcurrency: { concurrency.current() },
                onProgress: { bytes, total in liveBytes.record(bytes, total: total) }
            )
            ticker.cancel()
            // Final position, so the UI never stalls one tick short of the end.
            recordProgress(
                jobID: jobID,
                bytes: outcome.bytesWritten,
                total: outcome.identity.contentLength
            )

            if cancelledJobIDs.contains(jobID) || abort.isSet && cancelledJobIDs.contains(jobID) {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: .cancelled,
                    terminalReason: "userCancelled", expectedRevision: nil
                )
                cancelledJobIDs.remove(jobID)
                progressLedger.remove(jobID)
                return
            }
            if pausedJobIDs.contains(jobID) {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: .paused,
                    terminalReason: nil, expectedRevision: nil
                )
                pausedJobIDs.remove(jobID)
                progressLedger.set(
                    JobProgressSnapshot(
                        bytesTransferred: outcome.bytesWritten,
                        totalBytes: outcome.identity.contentLength,
                        speedBytesPerSecond: 0
                    ),
                    for: jobID
                )
                speedEstimators[jobID] = nil
                return
            }

            // Record that the host tolerates ranged GETs. Never store the
            // segment count we chose for this file size — a 20 MB download
            // must not poison an 8 GB follow-up to 4 segments for a week.
            //
            // Where the ramp *settled* is different: it is a starting point rather
            // than a cap, and `preferredSegmentCount` still applies the size rule
            // downstream. Only kept when the ramp actually climbed — a transfer
            // that ended at its starting value learned nothing worth storing, and
            // one that never ramped at all (small file, or an explicit user
            // setting) would otherwise write back a number it never tested.
            if outcome.segmentCount > 1 {
                let settled = connectionRamps[jobID]
                    .map(\.current)
                    .flatMap { $0 > connectionTarget ? $0 : nil }
                try? HostObservationRepository.set(
                    database: database,
                    host: host,
                    observation: HostObservationRepository.Observation(
                        maxSegments: nil,
                        rangeOK: true,
                        settledConnections: settled ?? learnedConnections
                    ),
                    expiresAt: Date().addingTimeInterval(7 * 24 * 60 * 60)
                )
            }

            try JobRepository.updateResourceIdentity(
                database: database,
                jobID: jobID,
                finalURL: outcome.identity.finalURL,
                expectedSize: outcome.bytesWritten,
                etag: outcome.identity.etag,
                mime: outcome.identity.contentType,
                contentDisposition: outcome.identity.contentDisposition
            )
            let betterName = FilenameSanitizer.preferredFilename(
                contentDisposition: outcome.identity.contentDisposition,
                urlString: outcome.identity.finalURL,
                existingEvidence: details.suggestedFilename,
                contentType: outcome.identity.contentType
            )
            Self.refineCategoryIfOther(
                database: database,
                jobID: jobID,
                filenameEvidence: betterName,
                mimeEvidence: outcome.identity.contentType,
                url: outcome.identity.finalURL
            )

            // CD / MIME often arrive only after the transfer — rename the
            // on-disk partial so promote lands on the real name (e.g. .mp4 / .html).
            let promotePaths = try Self.resolvePromotePaths(
                destinationDirectory: writeDirectory,
                startedFilename: filename,
                betterFilename: betterName,
                startedPartial: partial,
                startedFinal: final,
                conflictPolicy: conflictPolicy
            )

            try Self.finalizeDownloadedJob(
                database: database,
                jobID: jobID,
                details: details,
                promotePaths: promotePaths,
                bytesWritten: outcome.bytesWritten,
                mimeEvidence: outcome.identity.contentType,
                progressLedger: progressLedger,
                attemptByJob: &attemptByJob
            )
        } catch TransferCore.TransferError.aborted {
            await handleAbort(jobID: jobID)
        } catch is HeaderValidator.ParseError {
            _ = try? JobRepository.updateJobState(
                database: database, id: jobID, state: .failed,
                terminalReason: "dependencyProtocolMismatch", expectedRevision: nil
            )
            progressLedger.remove(jobID)
            attemptByJob[jobID] = nil
            log.error("job rejected invalid headers id=\(jobID, privacy: .public)")
        } catch {
            await handleFailure(jobID: jobID, error: error)
        }
    }

    private func buildDownloadOptions(
        from details: TransferJobDetails,
        hostSetting: HostSettingRepository.Setting?
    ) throws -> TransferCore.DownloadOptions {
        var options = TransferCore.DownloadOptions()
        let credentialID = details.credentialProfileID ?? hostSetting?.credentialProfileID
        if let credentialID {
            options.userpwd = try ProfileRepository.loadUserpwd(
                database: database,
                profileID: credentialID,
                secretStore: secretStore
            )
        }
        if let proxyID = details.proxyProfileID {
            options.proxyURL = try ProfileRepository.loadProxyURL(
                database: database,
                profileID: proxyID
            )
        }
        if let cookieID = details.cookieProfileID {
            options.cookieJarPath = try ProfileRepository.cookieJarPath(
                database: database,
                profileID: cookieID,
                applicationSupportRoot: applicationSupportRoot
            )
        }
        let parsedHeaders = try HeaderValidator.parseExtraHeadersJSON(details.customHeadersJSON)
        var headers = parsedHeaders.map {
            TransferCore.HTTPHeader(name: $0.name, value: $0.value)
        }
        // Host UA only when the job did not already set User-Agent. libcurl's
        // header list overrides CURLOPT_USERAGENT when the name is present.
        if let userAgent = hostSetting?.userAgent, !userAgent.isEmpty {
            let alreadySet = headers.contains {
                $0.name.compare("User-Agent", options: [.caseInsensitive]) == .orderedSame
            }
            if !alreadySet {
                headers.insert(TransferCore.HTTPHeader(name: "User-Agent", value: userAgent), at: 0)
            }
        }
        options.extraHeaders = headers
        // Only the PER-JOB override lives here; `0` means unlimited. The global
        // and per-host ceilings are enforced by the shared limiter the caller
        // attaches, because they are aggregate limits and cannot be expressed as
        // a number copied into each transfer's own budget.
        options.maxBytesPerSecond = max(0, details.maxBytesPerSecond ?? 0)
        return options
    }

    /// Rate limit the global calendar policy imposes right now, or `nil` when no
    /// policy exists or its window is closed.
    private func activeGlobalBandwidthLimit() throws -> Int64? {
        guard let policy = try ProfileRepository.fetchGlobalBandwidthPolicy(database: database) else {
            return nil
        }
        let windows = try BandwidthWindowEvaluator.parseWindowsJSON(policy.windowsJSON)
        guard BandwidthWindowEvaluator.isActive(now: Date(), calendar: .current, windows: windows) else {
            return nil
        }
        return policy.maxBytesPerSecond
    }

    /// The narrowest rate a job is subject to right now, for display only.
    ///
    /// Precedence: per-job > per-host > global calendar policy. This is what the
    /// inspector shows; it is deliberately NOT what throttles the transfer. The
    /// three limits have different scopes — the per-job value budgets one
    /// transfer, while the host and global values are shared across every
    /// concurrent transfer — so collapsing them to one number and copying it into
    /// each job is exactly the bug this slice fixes.
    static func effectiveMaxBytesPerSecond(
        perJob: Int64?,
        hostLimit: Int64? = nil,
        globalPolicyLimit: Int64?
    ) -> Int64? {
        if let perJob, perJob > 0 {
            return perJob
        }
        if let hostLimit, hostLimit > 0 {
            return hostLimit
        }
        return globalPolicyLimit
    }

    /// Default parallel connections when the job/host did not set a preference.
    /// Kept well below the per-host ceiling (32) so several concurrent downloads
    /// to one CDN each get a usable share instead of one job taking every slot.
    static let defaultConnectionsPerJob = 8

    /// Resolve how many connections one job may open on a host.
    ///
    /// - `preferredConnectionCount` (job or host setting) wins when present.
    /// - Otherwise use ``defaultConnectionsPerJob``.
    /// - Always clamp to `fairHostCap` (per-host ceiling ÷ jobs on that host).
    static func connectionTarget(preferredConnectionCount: Int?, fairHostCap: Int) -> Int {
        let fair = max(1, fairHostCap)
        let want = preferredConnectionCount.map { max(1, $0) } ?? defaultConnectionsPerJob
        return min(want, fair)
    }

    /// Extra sockets to reserve after the primary acquire (`target - 1`).
    static func requestedExtraSockets(preferredConnectionCount: Int?) -> Int {
        max(0, connectionTarget(preferredConnectionCount: preferredConnectionCount, fairHostCap: 32) - 1)
    }

    /// Segment ceiling handed to `SegmentedTransfer`. The socket reservation is
    /// the hard bound — a user asking for 64 connections still cannot exceed what
    /// the budget granted for this host.
    static func effectiveHostMaxSegments(preferredConnectionCount: Int?, socketBudget: Int) -> Int {
        let budget = max(1, socketBudget)
        guard let preferredConnectionCount else { return budget }
        return min(max(1, preferredConnectionCount), budget)
    }

    /// One progress tick, whether or not bytes arrived.
    ///
    /// A quiet tick re-reports the same cumulative count, so the estimator sees
    /// an interval with zero bytes in it and decays toward zero instead of
    /// holding the last live figure. `recordProgress` takes `max()` of the byte
    /// count, so re-reporting can never walk progress backwards.
    private func tickProgress(jobID: String, sample: (bytes: Int64, total: Int64?)?) {
        if let sample {
            recordProgress(jobID: jobID, bytes: sample.bytes, total: sample.total)
        } else if let previous = progressLedger.snapshot(for: jobID) {
            recordProgress(
                jobID: jobID,
                bytes: previous.bytesTransferred,
                total: previous.totalBytes
            )
        }
    }

    /// Highest concurrency the ramp may grow one transfer to on a host.
    ///
    /// Two separate limits, and both matter:
    ///
    /// - **`fairCap`** is this job's share of the host right now. It is re-read on
    ///   every step, so a download that starts later immediately stops the older
    ///   one from climbing further.
    /// - **The floor** keeps `activeJobLimit - 1` sockets unspent, because
    ///   `tryAcquireSocket` refuses a job that cannot get even a primary socket.
    ///   Without it a transfer that ramped *before* its siblings existed would
    ///   hold the whole host allowance, and every later download from that site
    ///   would sit in `queued`, retrying every 200 ms, until the first finished.
    ///
    /// The fair share alone does not cover that case: it is computed from the jobs
    /// counted on the host *at the time of the step*, so nothing shrinks a grant
    /// that was already made.
    static func rampGrowthCeiling(fairCap: Int, hostMax: Int, activeJobLimit: Int) -> Int {
        let reservedForSiblings = max(0, activeJobLimit - 1)
        return max(1, min(fairCap, hostMax - reservedForSiblings))
    }

    /// One ramp step: has the transfer earned another connection, and can the
    /// budget actually pay for it?
    ///
    /// The order matters. Sockets are reserved **before** the target is raised, so
    /// the transport is never told it may run more connections than the host
    /// budget has granted. A refused reservation simply leaves the target where it
    /// is — the transfer keeps running at its current width, and the ramp will ask
    /// again on a later tick.
    private func stepConnectionRamp(
        jobID: String,
        host: String,
        grant: SocketGrant,
        target: ConcurrencyTarget
    ) async {
        guard var ramp = connectionRamps[jobID], !ramp.settled else { return }
        guard let snapshot = progressLedger.snapshot(for: jobID) else { return }

        let want = ramp.record(
            totalBytes: snapshot.bytesTransferred,
            at: ProcessInfo.processInfo.systemUptime
        )
        connectionRamps[jobID] = ramp

        let held = 1 + grant.extra
        // Re-read the fair share every step. A download that started after this
        // one must be able to stop it climbing, and must still find a socket left
        // to start with.
        let ceiling = await Self.rampGrowthCeiling(
            fairCap: budget.fairConnectionCap(forHost: host),
            hostMax: budget.maxSocketsPerHostLimit(),
            activeJobLimit: budget.maxActiveJobsLimit()
        )
        let allowed = min(want, ceiling)
        guard allowed > held else { return }
        let granted = await budget.reserveSockets(host: host, upTo: allowed - held)
        guard granted > 0 else { return }
        grant.add(granted)
        target.raise(to: held + granted)
        log.debug(
            "ramp id=\(jobID, privacy: .public) connections=\(held + granted, privacy: .public)"
        )
    }

    private func recordProgress(jobID: String, bytes: Int64, total: Int64?) {
        let previous = progressLedger.snapshot(for: jobID)
        var snap = previous ?? JobProgressSnapshot(
            bytesTransferred: 0, totalBytes: total, speedBytesPerSecond: 0
        )
        snap.bytesTransferred = max(bytes, snap.bytesTransferred)
        if let total { snap.totalBytes = total }

        var estimator = speedEstimators[jobID] ?? TransferSpeedEstimator()
        snap.speedBytesPerSecond = estimator.record(bytes: bytes)
        speedEstimators[jobID] = estimator
        progressLedger.set(snap, for: jobID)
    }

    private func zeroSpeed(jobID: String, bytesTransferred: Int64? = nil, totalBytes: Int64? = nil) {
        speedEstimators[jobID] = nil
        let previous = progressLedger.snapshot(for: jobID)
        let bytes = bytesTransferred ?? previous?.bytesTransferred ?? 0
        let total = totalBytes ?? previous?.totalBytes
        progressLedger.set(
            JobProgressSnapshot(
                bytesTransferred: bytes,
                totalBytes: total,
                speedBytesPerSecond: 0
            ),
            for: jobID
        )
    }

    private func handleAbort(jobID: String) async {
        if cancelledJobIDs.contains(jobID) {
            _ = try? JobRepository.updateJobState(
                database: database, id: jobID, state: .cancelled,
                terminalReason: "userCancelled", expectedRevision: nil
            )
            cancelledJobIDs.remove(jobID)
            resumeAfterAbort.remove(jobID)
            progressLedger.remove(jobID)
            speedEstimators[jobID] = nil
            return
        }
        if resumeAfterAbort.contains(jobID) {
            resumeAfterAbort.remove(jobID)
            pausedJobIDs.remove(jobID)
            _ = try? JobRepository.requeueActiveTransferJob(database: database, id: jobID)
            zeroSpeed(jobID: jobID)
            log.info("job requeued after abort id=\(jobID, privacy: .public)")
            return
        }
        _ = try? JobRepository.updateJobState(
            database: database, id: jobID, state: .paused,
            terminalReason: nil, expectedRevision: nil
        )
        pausedJobIDs.remove(jobID)
        zeroSpeed(jobID: jobID)
        log.info("job paused id=\(jobID, privacy: .public)")
    }

    /// Blocking libcurl work must not sit on the orchestrator actor (pauses pump).
    private nonisolated static func downloadOffActor(
        url: String,
        partialURL: URL,
        options: TransferCore.DownloadOptions,
        abortFlag: TransferAbortFlag,
        hostMaxSegments: Int?,
        desiredConcurrency: (@Sendable () -> Int)? = nil,
        onProgress: @escaping TransferCore.ProgressHandler
    ) async throws -> SegmentedTransfer.Outcome {
        try await Task.detached(priority: .high) {
            try SegmentedTransfer.downloadHTTP(
                url: url,
                partialURL: partialURL,
                options: options,
                abortFlag: abortFlag,
                onProgress: onProgress,
                preferResume: true,
                hostMaxSegments: hostMaxSegments,
                desiredConcurrency: desiredConcurrency
            )
        }.value
    }

    /// Tiny ranged probe so Content-Disposition / MIME can name the job before bytes land.
    private func resumeFinalization(_ jobID: String) async {
        guard await budget.tryBeginJob() else { return }
        defer {
            let budget = self.budget
            Task.detached { await budget.endJob() }
            abortFlags[jobID] = nil
            endSleepAssertion(for: jobID)
        }

        do {
            let details = try JobRepository.loadJobForTransfer(database: database, id: jobID)
            guard let state = JobState(rawValue: details.state),
                  state == .verifying || state == .postProcessing
            else {
                return
            }
            guard let intent = try FinalizationIntentRepository.fetchIntent(
                database: database,
                jobID: jobID
            ) else {
                return
            }

            let accessed = details.destinationDirectory.startAccessingSecurityScopedResource()
            defer {
                if accessed { details.destinationDirectory.stopAccessingSecurityScopedResource() }
            }

            let partial = details.writeDirectory
                .appendingPathComponent(intent.partialFilename)
            let final = details.writeDirectory
                .appendingPathComponent(intent.finalFilename)

            try Self.runFinalizationPipeline(
                database: database,
                jobID: jobID,
                state: state,
                intentStage: FinalizationIntentStage(rawValue: intent.stage) ?? .prepared,
                partialURL: partial,
                finalURL: final,
                expectedByteSize: intent.expectedByteSize,
                expectedChecksum: intent.expectedChecksum,
                zipAutoExtract: intent.zipAutoExtract,
                progressLedger: progressLedger,
                attemptByJob: &attemptByJob
            )
        } catch {
            await handleFailure(jobID: jobID, error: error)
        }
    }

    private nonisolated static func finalizeDownloadedJob(
        database: EngineDatabase,
        jobID: String,
        details: TransferJobDetails,
        promotePaths: (partial: URL, final: URL),
        bytesWritten: Int64,
        mimeEvidence: String?,
        progressLedger: JobProgressLedger,
        attemptByJob: inout [String: Int]
    ) throws {
        let zipAutoExtract = shouldExtractZip(
            filename: promotePaths.final.lastPathComponent,
            mimeEvidence: mimeEvidence
        ) && AgentBoolSettings.bool(forKey: AgentBoolSettings.zipAutoExtractEnabledKey)

        _ = try FinalizationIntentRepository.beginVerification(
            database: database,
            jobID: jobID,
            finalFilename: promotePaths.final.lastPathComponent,
            partialFilename: promotePaths.partial.lastPathComponent,
            expectedByteSize: bytesWritten,
            expectedChecksum: details.expectedChecksum,
            zipAutoExtract: zipAutoExtract
        )

        try runFinalizationPipeline(
            database: database,
            jobID: jobID,
            state: .verifying,
            intentStage: .prepared,
            partialURL: promotePaths.partial,
            finalURL: promotePaths.final,
            expectedByteSize: bytesWritten,
            expectedChecksum: details.expectedChecksum,
            zipAutoExtract: zipAutoExtract,
            progressLedger: progressLedger,
            attemptByJob: &attemptByJob
        )
    }

    private nonisolated static func runFinalizationPipeline(
        database: EngineDatabase,
        jobID: String,
        state: JobState,
        intentStage: FinalizationIntentStage,
        partialURL: URL,
        finalURL: URL,
        expectedByteSize: Int64,
        expectedChecksum: String?,
        zipAutoExtract: Bool,
        progressLedger: JobProgressLedger,
        attemptByJob: inout [String: Int]
    ) throws {
        if state == .verifying, intentStage == .prepared {
            if let expectedChecksum, !expectedChecksum.isEmpty {
                try IntegrityVerifier.verifySHA256(ofFile: partialURL, expectedHex: expectedChecksum)
            }
            try TransferFinalizer.promote(
                partialURL: partialURL,
                finalURL: finalURL,
                expectedSize: expectedByteSize
            )
            _ = try FinalizationIntentRepository.markPromoted(database: database, jobID: jobID)
        }

        if zipAutoExtract {
            do {
                let basename = finalURL.deletingPathExtension().lastPathComponent
                let extractDir = finalURL.deletingLastPathComponent()
                    .appendingPathComponent("\(basename)-extracted", isDirectory: true)
                try SafeZipExtractor.extract(
                    archiveURL: finalURL,
                    destinationDirectory: extractDir
                )
            } catch {
                _ = try JobRepository.updateJobState(
                    database: database, id: jobID, state: .failed,
                    terminalReason: "postProcessingFailed", expectedRevision: nil
                )
                _ = try? database.pool.write { db in
                    try FinalizationIntentRecord.deleteOne(db, key: jobID)
                }
                progressLedger.remove(jobID)
                attemptByJob[jobID] = nil
                EngineLog.agent.error(
                    "zip post-process failed id=\(jobID, privacy: .public) err=\(EngineLog.redacted(error), privacy: .public)"
                )
                return
            }
        }

        _ = try FinalizationIntentRepository.completeFinalization(database: database, jobID: jobID)
        progressLedger.set(
            JobProgressSnapshot(
                bytesTransferred: expectedByteSize,
                totalBytes: expectedByteSize,
                speedBytesPerSecond: 0
            ),
            for: jobID
        )
        attemptByJob[jobID] = nil
        EngineLog.agent.info("job completed id=\(jobID, privacy: .public)")
    }

    private nonisolated static func probeOffActor(
        url: String,
        options: TransferCore.DownloadOptions
    ) async throws -> TransferCore.ResourceIdentity {
        try await Task.detached(priority: .utility) {
            try TransferCore.probeRangeSupport(url: url, options: options)
        }.value
    }

    /// When Content-Disposition / MIME improves the name after bytes land,
    /// move the `.partial` (+ `.segmap`) so promote uses the real filename.
    private nonisolated static func resolvePromotePaths(
        destinationDirectory: URL,
        startedFilename: String,
        betterFilename: String,
        startedPartial: URL,
        startedFinal: URL,
        conflictPolicy: DestinationConflictPolicy
    ) throws -> (partial: URL, final: URL) {
        let better = FilenameSanitizer.sanitize(betterFilename)
        guard better != startedFilename, !better.isEmpty else {
            return (startedPartial, startedFinal)
        }

        var preferredFinal = destinationDirectory.appendingPathComponent(better)
        let destinationExists = FileManager.default.fileExists(atPath: preferredFinal.path)
        switch DestinationConflictResolver.action(
            policy: conflictPolicy,
            destinationExists: destinationExists
        ) {
        case .usePreferred, .overwrite:
            break
        case .uniquify:
            preferredFinal = Self.uniquifiedDestinationURL(preferredFinal)
        case .fail:
            // Keep the name we already downloaded under rather than failing late.
            return (startedPartial, startedFinal)
        }

        let preferredPartial = destinationDirectory
            .appendingPathComponent("\(preferredFinal.lastPathComponent).partial")
        let fm = FileManager.default
        if startedPartial.path != preferredPartial.path {
            if fm.fileExists(atPath: preferredPartial.path) {
                try fm.removeItem(at: preferredPartial)
            }
            try fm.moveItem(at: startedPartial, to: preferredPartial)
            let oldMap = URL(fileURLWithPath: startedPartial.path + ".segmap")
            let newMap = URL(fileURLWithPath: preferredPartial.path + ".segmap")
            if fm.fileExists(atPath: oldMap.path) {
                try? fm.removeItem(at: newMap)
                try fm.moveItem(at: oldMap, to: newMap)
            }
        }
        return (preferredPartial, preferredFinal)
    }

    private nonisolated static func uniquifiedDestinationURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for i in 2 ..< 10000 {
            let candidate = ext.isEmpty
                ? dir.appendingPathComponent("\(base) (\(i))")
                : dir.appendingPathComponent("\(base) (\(i)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return dir.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
    }

    /// The directory this job's bytes are written into: the destination itself, or
    /// a category subfolder inside it.
    ///
    /// Throws rather than falling back to the parent directory. Silently writing
    /// somewhere other than where the row says the file is would be worse than a
    /// visible failure — and a resumed job that fell back would look for its
    /// `.partial` in the wrong place and start over.
    private nonisolated static func resolveWriteDirectory(
        database: EngineDatabase,
        details: TransferJobDetails
    ) throws -> URL {
        let stamped = try JobRepository.stampCategorySubfolder(
            database: database,
            jobID: details.jobID,
            enabled: AgentBoolSettings.bool(forKey: AgentBoolSettings.categoryFoldersEnabledKey)
        )
        guard let stamped else { return details.destinationDirectory }
        let directory = details.destinationDirectory.appendingPathComponent(
            stamped,
            isDirectory: true
        )
        // `createDirectory` succeeds if the directory exists, but throws when a
        // plain *file* already sits at that name — which is exactly the case that
        // must not be papered over.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// Auto-assign built-in categories when the job is still `other`.
    private nonisolated static func refineCategoryIfOther(
        database: EngineDatabase,
        jobID: String,
        filenameEvidence: String?,
        mimeEvidence: String?,
        url: String
    ) {
        let classified = ClassificationEngine.classify(
            filenameEvidence: filenameEvidence,
            mimeEvidence: mimeEvidence,
            urlPath: url
        )
        guard classified.stableKey != "other" else { return }
        do {
            _ = try JobRepository.upgradeCategoryFromOther(
                database: database,
                jobID: jobID,
                categoryStableKey: classified.stableKey
            )
        } catch {
            EngineLog.agent.error(
                "category refine failed id=\(jobID, privacy: .public) err=\(EngineLog.redacted(error), privacy: .public)"
            )
        }
    }

    /// Whether another attempt could plausibly succeed.
    ///
    /// A digest mismatch cannot: the retry resumes the same partial through the
    /// same segment map and hashes the same bytes, so three attempts produce
    /// three identical failures and the user waits out the backoff for nothing.
    /// Restart (which wipes the partial) is the recovery, and the user drives it.
    static func isRetryable(_ error: Error) -> Bool {
        if case IntegrityVerifier.VerifyError.checksumMismatch = error {
            return false
        }
        return true
    }

    private func handleFailure(jobID: String, error: Error) async {
        log.error("job failed id=\(jobID, privacy: .public) err=\(EngineLog.redacted(error), privacy: .public)")
        let attempt = (attemptByJob[jobID] ?? 0) + 1
        attemptByJob[jobID] = attempt

        let httpStatus: Int?
        let retryAfterSeconds: Double?
        if case let TransferCore.TransferError.httpStatus(code, retryAfter) = error {
            httpStatus = code
            retryAfterSeconds = retryAfter
        } else {
            httpStatus = nil
            retryAfterSeconds = nil
        }

        if Self.isRetryable(error), retryPolicy.shouldRetry(attempt: attempt, httpStatus: httpStatus) {
            // Honour the server's own `Retry-After` when it sent one. This used to
            // pass nil unconditionally, so a 429 was answered on our schedule
            // rather than theirs — coming back early just earns another refusal
            // and spends one of only `maxAttempts` whole-job attempts.
            // `RetryPolicy` caps the value, so a hostile header cannot park a job.
            let delay = retryPolicy.delayNanoseconds(
                attempt: attempt - 1,
                retryAfterSeconds: retryAfterSeconds
            )
            _ = try? JobRepository.updateJobState(
                database: database, id: jobID, state: .retryWaiting,
                terminalReason: nil, expectedRevision: nil
            )
            try? await Task.sleep(nanoseconds: delay)
            if cancelledJobIDs.contains(jobID) {
                _ = try? JobRepository.updateJobState(
                    database: database, id: jobID, state: .cancelled,
                    terminalReason: "userCancelled", expectedRevision: nil
                )
                cancelledJobIDs.remove(jobID)
                return
            }
            if pausedJobIDs.contains(jobID) {
                _ = try? JobRepository.updateJobState(
                    database: database, id: jobID, state: .paused,
                    terminalReason: nil, expectedRevision: nil
                )
                pausedJobIDs.remove(jobID)
                return
            }
            _ = try? JobRepository.requeueActiveTransferJob(database: database, id: jobID)
            return
        }

        let reason = if case let TransferCore.TransferError.httpStatus(code, _) = error {
            switch code {
            case 401, 403: "authenticationRejected"
            case 404, 410: "notFound"
            case 429: "serverRateLimited"
            case 500 ... 599: "serverUnavailable"
            default: "networkUnavailable"
            }
        } else if case TransferFinalizer.FinalizerError.sizeMismatch = error {
            "rangeProtocolViolation"
        } else if case IntegrityVerifier.VerifyError.checksumMismatch = error {
            "checksumMismatch"
        } else if case SafeZipExtractor.ExtractError.unsafePath = error {
            "unsafePath"
        } else if error is SafeZipExtractor.ExtractError {
            "postProcessingFailed"
        } else {
            "networkUnavailable"
        }
        _ = try? JobRepository.updateJobState(
            database: database, id: jobID, state: .failed,
            terminalReason: reason, expectedRevision: nil
        )
        attemptByJob[jobID] = nil
    }

    private func beginSleepAssertion(for jobID: String) {
        endSleepAssertion(for: jobID)
        if let token = sleepAssertionHolder.beginTransferAssertion(
            reason: "DownloadManager transfer"
        ) {
            sleepAssertions[jobID] = token
        }
    }

    private func endSleepAssertion(for jobID: String) {
        guard let token = sleepAssertions.removeValue(forKey: jobID) else { return }
        sleepAssertionHolder.endTransferAssertion(token)
    }

    private func uniquifiedURL(_ url: URL) -> URL {
        Self.uniquifiedDestinationURL(url)
    }

    /// ZIP post-process when filename ends with `.zip` or MIME evidence mentions zip.
    static func shouldExtractZip(filename: String, mimeEvidence: String?) -> Bool {
        if filename.lowercased().hasSuffix(".zip") { return true }
        if let mimeEvidence, mimeEvidence.lowercased().contains("zip") { return true }
        return false
    }
}
