// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import XPCContracts

/// How an enqueue request was satisfied.
public struct NativeMessagingEnqueueOutcome: Sendable, Equatable {
    public var route: NativeMessagingProtocol.Route
    public var acceptedCount: Int
    public var jobIDs: [String]

    public init(route: NativeMessagingProtocol.Route, acceptedCount: Int, jobIDs: [String]) {
        self.route = route
        self.acceptedCount = acceptedCount
        self.jobIDs = jobIDs
    }
}

/// Failures the router turns into a specific answer instead of a generic one.
public enum NativeMessagingBridgeError: Error, Equatable, Sendable {
    /// The engine could not be reached over XPC.
    case engineUnavailable
    /// The engine could not be reached and the app could not be opened either.
    case appUnavailable
}

/// Engine operations exposed to the Native Messaging router.
public protocol NativeMessagingEngineBridge: Sendable {
    func enqueue(
        urls: [String],
        displayName: String?,
        customHeadersJSON: String?
    ) async throws -> NativeMessagingEnqueueOutcome
    func listJobCount() async throws -> Int
}

/// Routes Native Messaging commands to the engine over XPC.
public struct NativeMessagingRouter: Sendable {
    private let engine: any NativeMessagingEngineBridge

    public init(engine: any NativeMessagingEngineBridge) {
        self.engine = engine
    }

    public func handle(body: Data) async -> Data {
        let request: NativeMessagingProtocol.Request
        do {
            request = try NativeMessagingProtocol.decodeRequest(from: body)
        } catch let NativeMessagingProtocol.DecodeError.unsupportedProtocolVersion(version) {
            // Answer at the version this host speaks so the extension can retry
            // on an envelope it knows both sides understand.
            return encode(NativeMessagingProtocol.Response.failure(
                requestID: "unknown",
                errorCode: "unsupportedProtocolVersion",
                message: "This copy of Flow speaks native messaging version "
                    + "\(NativeMessagingProtocol.currentVersion), not \(version)."
            ))
        } catch {
            return encode(NativeMessagingProtocol.Response.failure(
                requestID: "unknown",
                errorCode: "invalidJSON",
                message: "The request could not be read."
            ))
        }

        do {
            return try await NativeMessagingProtocol.encodeResponse(dispatch(request))
        } catch let error as NativeMessagingBridgeError {
            return encode(failure(for: error, request: request))
        } catch {
            return encode(NativeMessagingProtocol.Response.failure(
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                errorCode: "engineError",
                message: "Flow could not accept the download. Open Flow and try again."
            ))
        }
    }

    /// Stdio host entry uses a blocking loop; bridge async XPC without top-level await.
    public func handleSynchronously(body: Data) -> Data {
        final class Box: @unchecked Sendable {
            var value = Data()
        }
        let box = Box()
        let gate = DispatchSemaphore(value: 0)
        Task {
            box.value = await handle(body: body)
            gate.signal()
        }
        gate.wait()
        return box.value
    }

    private func encode(_ response: NativeMessagingProtocol.Response) -> Data {
        (try? NativeMessagingProtocol.encodeResponse(response)) ?? Data("{}".utf8)
    }

    private func failure(
        for error: NativeMessagingBridgeError,
        request: NativeMessagingProtocol.Request
    ) -> NativeMessagingProtocol.Response {
        switch error {
        case .engineUnavailable:
            return NativeMessagingProtocol.Response.failure(
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                errorCode: "engineUnavailable",
                message: "Flow's background engine is not answering. Open Flow, then try again."
            )
        case .appUnavailable:
            return NativeMessagingProtocol.Response.failure(
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                errorCode: "appUnavailable",
                message: "Flow Download Manager could not be opened, so the download was not accepted."
            )
        }
    }

    private func dispatch(
        _ request: NativeMessagingProtocol.Request
    ) async throws -> NativeMessagingProtocol.Response {
        switch request.command {
        case .ping:
            return NativeMessagingProtocol.Response(
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                ok: true,
                message: "pong"
            )
        case .enqueueURLs:
            return try await enqueue(request)
        case .listJobs:
            let count = try await engine.listJobCount()
            return NativeMessagingProtocol.Response(
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                ok: true,
                jobCount: count
            )
        }
    }

    private func enqueue(
        _ request: NativeMessagingProtocol.Request
    ) async throws -> NativeMessagingProtocol.Response {
        let urls = request.urls ?? []
        let extraction = URLTextExtractor.extract(from: urls.joined(separator: "\n"))
        let valid = extraction.items.compactMap { item -> String? in
            guard item.status == .valid, let normalized = item.normalized else { return nil }
            return normalized
        }
        guard !valid.isEmpty else {
            return NativeMessagingProtocol.Response.failure(
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                errorCode: "noValidURLs",
                message: "No downloadable link was found."
            )
        }

        let policy = NativeMessagingHeaderPolicy.sanitize(request.headers, urlCount: valid.count)
        let outcome = try await engine.enqueue(
            urls: valid,
            displayName: request.displayName,
            customHeadersJSON: policy.customHeadersJSON
        )

        var dropped = policy.droppedNames
        var warningCode: String?
        var message: String?

        switch outcome.route {
        case .engine:
            if !dropped.isEmpty {
                warningCode = "headersNotForwarded"
                message = "Queued. Some request details were not sent: \(dropped.joined(separator: ", "))."
            }
        case .appHandoff:
            // The custom-scheme hand-off carries URLs only, by design.
            for name in policy.forwardedNames where !dropped.contains(name) {
                dropped.append(name)
            }
            warningCode = "openedInAppWithoutHeaders"
            message = dropped.isEmpty
                ? "Flow's background engine is off, so the links were opened in Flow. Click Add to start them."
                : "Flow's background engine is off, so the links were opened in Flow. "
                + "Click Add to start them. Sign-in details were not carried over."
        }

        return NativeMessagingProtocol.Response(
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            ok: true,
            message: message,
            acceptedCount: outcome.acceptedCount,
            jobIDs: outcome.jobIDs,
            route: outcome.route,
            droppedHeaderNames: dropped.isEmpty ? nil : dropped,
            warningCode: warningCode
        )
    }
}
