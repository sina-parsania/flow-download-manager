// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Domain
import Foundation
import XPCContracts

/// Non-UI XPC client used by the Chrome Native Messaging host.
///
/// The Mach service only exists on a signed install where the LaunchAgent is
/// registered. Community builds run the engine as the app-scoped XPC service
/// bundled in `Contents/XPCServices` (ADR 0008), which a helper process outside
/// the app cannot address — and the app unregisters the LaunchAgent when it heals
/// onto that service. So a transport failure here is the normal case, not an
/// error, and it falls back to handing the URLs to the app itself rather than
/// dropping the download.
public actor NativeHostEngineClient: NativeMessagingEngineBridge {
    public enum ClientError: Error, Sendable {
        case notConnected
        case remote(NSError)
        case decoding
        case timedOut
    }

    private var connection: NSXPCConnection?
    private var didHandshake = false
    private let handoff: any AppHandoffPerforming
    private let callTimeoutSeconds: Double
    private let handoffTimeoutSeconds: Double

    public init(
        handoff: any AppHandoffPerforming = WorkspaceAppHandoff(),
        callTimeoutSeconds: Double = 5.0,
        handoffTimeoutSeconds: Double = 20.0
    ) {
        self.handoff = handoff
        self.callTimeoutSeconds = callTimeoutSeconds
        self.handoffTimeoutSeconds = handoffTimeoutSeconds
    }

    public func connect() async throws {
        if connection != nil, didHandshake { return }

        let connection = NSXPCConnection(machServiceName: EngineXPC.machServiceName)
        connection.remoteObjectInterface = EngineControlInterface.make()
        connection.resume()
        self.connection = connection

        let hello = ClientHello(
            protocolVersion: SchemaVersions.xpcProtocol,
            clientBuild: "0.1.0-native-host",
            clientRole: .nativeHost,
            capabilities: ["enqueueBatch", "listJobs"]
        )
        let _: ServerHello = try await invoke { proxy, reply in
            proxy.handshake(hello, reply: reply)
        }
        didHandshake = true
    }

    public func enqueue(
        urls: [String],
        displayName: String?,
        customHeadersJSON: String?
    ) async throws -> NativeMessagingEnqueueOutcome {
        do {
            let response = try await enqueueOverXPC(
                urls: urls,
                displayName: displayName,
                customHeadersJSON: customHeadersJSON
            )
            return NativeMessagingEnqueueOutcome(
                route: .engine,
                acceptedCount: response.acceptedCount,
                jobIDs: response.jobIDs
            )
        } catch {
            guard Self.isTransportFailure(error) else { throw error }
            resetConnection()
            NativeHostLog.host.info("engine XPC unreachable; handing URLs to the app")
            do {
                try await handOffWithDeadline(urls: urls)
            } catch {
                NativeHostLog.host.error("app hand-off failed; download not accepted")
                throw NativeMessagingBridgeError.appUnavailable
            }
            return NativeMessagingEnqueueOutcome(
                route: .appHandoff,
                acceptedCount: min(urls.count, AppHandoffURL.maxURLCount),
                jobIDs: []
            )
        }
    }

    public func listJobCount() async throws -> Int {
        do {
            try await connect()
            let requestID = UUID().uuidString
            let snapshot: JobListSnapshot = try await invoke { proxy, reply in
                proxy.listJobs(requestID: requestID, reply: reply)
            }
            return snapshot.jobs.count
        } catch {
            guard Self.isTransportFailure(error) else { throw error }
            resetConnection()
            throw NativeMessagingBridgeError.engineUnavailable
        }
    }

    // MARK: - Private

    private func enqueueOverXPC(
        urls: [String],
        displayName: String?,
        customHeadersJSON: String?
    ) async throws -> EnqueueBatchResponse {
        try await connect()
        // The extension's own request ID is untrusted and the DTO requires a UUID;
        // mint a fresh one rather than forwarding what arrived over stdio.
        let request = EnqueueBatchRequest(
            requestID: UUID().uuidString,
            source: "chrome-extension",
            displayName: displayName,
            items: urls.map { url in
                let category = ClassificationEngine.classify(
                    filenameEvidence: URL(string: url)?.lastPathComponent,
                    mimeEvidence: nil,
                    urlPath: url
                ).stableKey
                return BatchURLItem(url: url, categoryStableKey: category)
            },
            credentialProfileID: nil,
            proxyProfileID: nil,
            cookieProfileID: nil,
            customHeadersJSON: customHeadersJSON,
            projectID: nil,
            scheduleStartAtISO8601: nil
        )
        return try await invoke { proxy, reply in
            proxy.enqueueBatch(request, reply: reply)
        }
    }

    /// Bounds the hand-off the way ``invoke`` bounds an XPC call. Launching an app
    /// can stall on a slow disk or a Gatekeeper prompt, and Chrome never times the
    /// host out — a stuck open would leave the user with no answer at all.
    private func handOffWithDeadline(urls: [String]) async throws {
        let handoff = handoff
        let seconds = handoffTimeoutSeconds
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await handoff.handOff(urls: urls)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ClientError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func resetConnection() {
        connection?.invalidate()
        connection = nil
        didHandshake = false
    }

    /// Runs one XPC call under a deadline.
    ///
    /// Chrome gives the host no timeout of its own: without this a stalled
    /// connection would wedge the host process and the user would see nothing at
    /// all rather than the hand-off.
    private func invoke<T: AnyObject & Sendable>(
        _ call: (EngineControlProtocol, @escaping @Sendable (T?, NSError?) -> Void) -> Void
    ) async throws -> T {
        let deadline = callTimeoutSeconds
        return try await withCheckedThrowingContinuation { continuation in
            let box = SingleResume<T>(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                box.resume(throwing: ClientError.timedOut)
            }
            guard let connection,
                  let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                      box.resume(throwing: ClientError.remote(error as NSError))
                  }) as? EngineControlProtocol
            else {
                box.resume(throwing: ClientError.notConnected)
                return
            }
            call(proxy) { value, error in
                if let error {
                    box.resume(throwing: ClientError.remote(error))
                } else if let value {
                    box.resume(returning: value)
                } else {
                    box.resume(throwing: ClientError.decoding)
                }
            }
        }
    }

    /// True when the engine could not be reached at all, as opposed to reaching it
    /// and being told no. Engine rejections carry ``XPCErrorDomain`` and must
    /// surface to the user unchanged.
    public static func isTransportFailure(_ error: Error) -> Bool {
        switch error {
        case ClientError.notConnected, ClientError.timedOut, ClientError.decoding:
            return true
        case let ClientError.remote(nsError):
            return nsError.domain != XPCErrorDomain
        default:
            return false
        }
    }
}

/// Resumes a continuation exactly once, whichever of the reply, the error handler
/// or the deadline arrives first.
private final class SingleResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        guard let continuation = take() else { return }
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard let continuation = take() else { return }
        continuation.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let pending = continuation
        continuation = nil
        return pending
    }
}
