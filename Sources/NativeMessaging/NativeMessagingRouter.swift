// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import Foundation
import XPCContracts

/// Engine operations exposed to the Native Messaging router.
public protocol NativeMessagingEngineBridge: Sendable {
    func enqueueURLs(_ urls: [String], displayName: String?) async throws -> (acceptedCount: Int, jobIDs: [String])
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
            let response = NativeMessagingProtocol.Response.failure(
                requestID: "unknown",
                errorCode: "unsupportedProtocolVersion",
                message: "unsupported protocolVersion \(version)"
            )
            return (try? NativeMessagingProtocol.encodeResponse(response)) ?? Data("{}".utf8)
        } catch {
            let response = NativeMessagingProtocol.Response.failure(
                requestID: "unknown",
                errorCode: "invalidJSON",
                message: "request decode failed"
            )
            return (try? NativeMessagingProtocol.encodeResponse(response)) ?? Data("{}".utf8)
        }

        do {
            let response = try await dispatch(request)
            return try NativeMessagingProtocol.encodeResponse(response)
        } catch {
            let response = NativeMessagingProtocol.Response.failure(
                requestID: request.requestID,
                errorCode: "engineError",
                message: "engine command failed"
            )
            return (try? NativeMessagingProtocol.encodeResponse(response)) ?? Data("{}".utf8)
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

    private func dispatch(
        _ request: NativeMessagingProtocol.Request
    ) async throws -> NativeMessagingProtocol.Response {
        switch request.command {
        case .ping:
            return NativeMessagingProtocol.Response(
                requestID: request.requestID,
                ok: true,
                message: "pong"
            )
        case .enqueueURLs:
            let urls = request.urls ?? []
            let extraction = URLTextExtractor.extract(from: urls.joined(separator: "\n"))
            let valid = extraction.items.compactMap { item -> String? in
                guard item.status == .valid, let normalized = item.normalized else { return nil }
                return normalized
            }
            guard !valid.isEmpty else {
                return NativeMessagingProtocol.Response.failure(
                    requestID: request.requestID,
                    errorCode: "noValidURLs",
                    message: "no valid download URLs"
                )
            }
            let result = try await engine.enqueueURLs(valid, displayName: request.displayName)
            return NativeMessagingProtocol.Response(
                requestID: request.requestID,
                ok: true,
                acceptedCount: result.acceptedCount,
                jobIDs: result.jobIDs
            )
        case .listJobs:
            let count = try await engine.listJobCount()
            return NativeMessagingProtocol.Response(
                requestID: request.requestID,
                ok: true,
                jobCount: count
            )
        }
    }
}
