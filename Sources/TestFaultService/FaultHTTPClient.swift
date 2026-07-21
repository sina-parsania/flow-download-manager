// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network

/// Minimal synchronous loopback HTTP/1.1 client used by integration tests to
/// exercise ``FaultHTTPServer`` without App Transport Security constraints on
/// `http://` (raw TCP, not URLSession). Test-support only.
public struct FaultHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public enum FaultHTTPClientError: Error, Sendable {
    case connectionFailed
    case timedOut
    case malformedResponse
}

public enum FaultHTTPClient {
    public static func get(
        port: UInt16, path: String, rangeHeader: String? = nil, timeout: TimeInterval = 5
    ) throws -> FaultHTTPResponse {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .http,
            using: .tcp
        )
        let queue = DispatchQueue(label: "org.downloadmanager.local.faultclient")
        let ready = DispatchSemaphore(value: 0)
        let box = ResponseBox()

        var request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let rangeHeader { request += "\(rangeHeader)\r\n" }
        request += "Connection: close\r\n\r\n"
        let requestData = Data(request.utf8)

        // Set the ready action BEFORE start() so no state callback can observe it
        // unset. All box state is lock-guarded (see ResponseBox).
        box.setOnReady {
            connection.send(content: requestData, completion: .contentProcessed { _ in
                receive(connection, box: box, done: ready)
            })
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: box.signalReady()
            case .failed: box.fail(); ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)

        if ready.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw FaultHTTPClientError.timedOut
        }
        connection.cancel()

        guard !box.isFailed() else { throw FaultHTTPClientError.connectionFailed }
        return try parse(box.data)
    }

    private static func receive(_ connection: NWConnection, box: ResponseBox, done: DispatchSemaphore) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, isComplete, error in
            if let data { box.append(data) }
            if isComplete || error != nil {
                done.signal()
            } else {
                receive(connection, box: box, done: done)
            }
        }
    }

    private static func parse(_ data: Data) throws -> FaultHTTPResponse {
        guard let separator = FaultHTTPServer.range(of: Data("\r\n\r\n".utf8), in: data) else {
            throw FaultHTTPClientError.malformedResponse
        }
        let headerData = data.subdata(in: 0 ..< separator.lowerBound)
        let body = data.subdata(in: separator.upperBound ..< data.count)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw FaultHTTPClientError.malformedResponse
        }
        let lines = headerString.components(separatedBy: "\r\n")
        let statusParts = (lines.first ?? "").split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw FaultHTTPClientError.malformedResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return FaultHTTPResponse(statusCode: status, headers: headers, body: body)
    }

    /// Lock-guarded shared state between the connection queue and the caller
    /// (Swift 6 / TSan clean). Every access acquires `lock`.
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var failed = false
        private var onReady: (() -> Void)?

        func setOnReady(_ action: @escaping () -> Void) {
            lock.lock(); onReady = action; lock.unlock()
        }

        func signalReady() {
            lock.lock(); let action = onReady; lock.unlock()
            action?()
        }

        var data: Data {
            lock.lock(); defer { lock.unlock() }; return buffer
        }

        func append(_ chunk: Data) {
            lock.lock(); buffer.append(chunk); lock.unlock()
        }

        func fail() {
            lock.lock(); failed = true; lock.unlock()
        }

        func isFailed() -> Bool {
            lock.lock(); defer { lock.unlock() }; return failed
        }
    }
}
