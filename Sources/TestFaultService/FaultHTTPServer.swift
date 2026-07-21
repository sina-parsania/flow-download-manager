// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network

/// Deterministic loopback HTTP/1.1 fault server for Phase 1 transfer tests
/// (`05-quality-testing-release-gates.md` §3, `08-validation-commands.md` §6).
/// Binds only to 127.0.0.1, serves fixed fixture bytes, and encodes fault
/// scenarios in the request path so tests are reproducible without the public
/// internet. Supports lifecycle, health, reset and request logs.
///
/// Routes (all under the bound port):
///   GET /health                  -> 200 "ok" (liveness)
///   GET /fixtures/ok             -> 200 with body, strong ETag, Accept-Ranges;
///                                    honors Range with 206 + Content-Range
///   GET /fixtures/no-range       -> 200 full body even when Range is requested
///   GET /fixtures/changing-etag  -> 200 with an ETag that changes each request
///   GET /fixtures/truncated      -> Content-Length larger than the bytes sent
///   GET /status/<code>           -> responds with that status code
///   POST /control/reset          -> clears request log + counters
///   GET  /control/logs           -> newline-delimited request log
public final class FaultHTTPServer: @unchecked Sendable {
    /// Fixed fixture payload (deterministic bytes).
    public static let fixtureBody = Data((0 ..< 4096).map { UInt8($0 % 251) })
    public static let strongETag = "\"dm-fixture-v1\""

    private let queue = DispatchQueue(label: "org.downloadmanager.local.faultservice")
    private let lock = NSLock()
    private var listener: NWListener?
    private var requestLog: [String] = []
    private var etagCounter = 0

    public private(set) var port: UInt16 = 0

    public init() {}

    /// Start on `127.0.0.1:<port>` (0 selects a free port). Returns the bound port.
    @discardableResult
    public func start(port requestedPort: UInt16 = 0) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        let listener = try NWListener(using: parameters, on: nwPort)

        let ready = DispatchSemaphore(value: 0)
        let startError = ErrorBox()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case let .failed(error):
                startError.set(error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener = listener
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw FaultServiceError.startTimedOut
        }
        if let error = startError.get() { throw error }
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public func reset() {
        lock.lock()
        requestLog.removeAll()
        etagCounter = 0
        lock.unlock()
    }

    public func logs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    // MARK: connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection
            .receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                var accumulated = buffer
                if let data { accumulated.append(data) }

                if let headerEnd = Self.range(of: Data("\r\n\r\n".utf8), in: accumulated) {
                    let headerData = accumulated.subdata(in: 0 ..< headerEnd.lowerBound)
                    respond(to: headerData, on: connection)
                    return
                }
                if error != nil || isComplete || accumulated.count > 64 * 1024 {
                    connection.cancel()
                    return
                }
                receiveRequest(connection, buffer: accumulated)
            }
    }

    private func respond(to headerData: Data, on connection: NWConnection) {
        guard let header = String(data: headerData, encoding: .utf8) else {
            send(status: 400, reason: "Bad Request", body: Data(), on: connection)
            return
        }
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: 400, reason: "Bad Request", body: Data(), on: connection)
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }

        lock.lock()
        requestLog.append("\(method) \(path)")
        lock.unlock()

        route(method: method, path: path, rangeHeader: rangeHeader, on: connection)
    }

    private func route(method: String, path: String, rangeHeader: String?, on connection: NWConnection) {
        switch path {
        case "/health":
            send(status: 200, reason: "OK", body: Data("ok".utf8), on: connection)

        case "/control/reset":
            reset()
            send(status: 200, reason: "OK", body: Data("reset".utf8), on: connection)

        case "/control/logs":
            send(status: 200, reason: "OK", body: Data(logs().joined(separator: "\n").utf8), on: connection)

        case "/fixtures/ok":
            serveFixture(rangeHeader: rangeHeader, acceptRanges: true, etag: Self.strongETag, on: connection)

        case "/fixtures/no-range":
            // Ignores Range: always returns the full 200 body.
            serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)

        case "/fixtures/changing-etag":
            lock.lock(); etagCounter += 1; let counter = etagCounter; lock.unlock()
            serveFixture(
                rangeHeader: rangeHeader,
                acceptRanges: true,
                etag: "\"changing-\(counter)\"",
                on: connection
            )

        case "/fixtures/truncated":
            // Declares more bytes than it sends, then closes (truncated body).
            let body = Self.fixtureBody.prefix(1024)
            var headers = "HTTP/1.1 200 OK\r\n"
            headers += "Content-Length: \(Self.fixtureBody.count)\r\n"
            headers += "Connection: close\r\n\r\n"
            var response = Data(headers.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })

        default:
            if path.hasPrefix("/status/"), let code = Int(path.dropFirst("/status/".count)) {
                send(status: code, reason: reason(for: code), body: Data("status \(code)".utf8), on: connection)
            } else {
                send(status: 404, reason: "Not Found", body: Data(), on: connection)
            }
        }
    }

    private func serveFixture(rangeHeader: String?, acceptRanges: Bool, etag: String, on connection: NWConnection) {
        let body = Self.fixtureBody
        if acceptRanges, let rangeHeader, let range = Self.parseRange(rangeHeader, total: body.count) {
            let slice = body.subdata(in: range)
            var headers = "HTTP/1.1 206 Partial Content\r\n"
            headers += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)\r\n"
            headers += "Content-Length: \(slice.count)\r\n"
            headers += "Accept-Ranges: bytes\r\n"
            headers += "ETag: \(etag)\r\n"
            headers += "Connection: close\r\n\r\n"
            var response = Data(headers.utf8)
            response.append(slice)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        var headers = "HTTP/1.1 200 OK\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        if acceptRanges { headers += "Accept-Ranges: bytes\r\n" }
        headers += "ETag: \(etag)\r\n"
        headers += "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func send(status: Int, reason: String, body: Data, on connection: NWConnection) {
        var headers = "HTTP/1.1 \(status) \(reason)\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: helpers

    static func parseRange(_ header: String, total: Int) -> Range<Int>? {
        // "Range: bytes=START-END" or "bytes=START-"
        guard let eq = header.firstIndex(of: "=") else { return nil }
        let spec = header[header.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard let lower = Int(bounds.first ?? "") else { return nil }
        // Clamp before +1 so a maximal (Int.max) end from the untrusted header cannot overflow-trap.
        let upper: Int = if bounds.count > 1, let end = Int(bounds[1]) { end >= total ? total : end + 1 } else { total }
        guard lower >= 0, lower < upper, upper <= total else { return nil }
        return lower ..< upper
    }

    static func range(of pattern: Data, in data: Data) -> Range<Int>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        let bytes = [UInt8](data)
        let needle = [UInt8](pattern)
        var i = 0
        while i <= bytes.count - needle.count {
            if Array(bytes[i ..< i + needle.count]) == needle { return i ..< (i + needle.count) }
            i += 1
        }
        return nil
    }

    private func reason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

public enum FaultServiceError: Error, Sendable {
    case startTimedOut
}

/// Lock-protected error holder for use across the listener's state callback and
/// the starting thread (Swift 6 concurrency).
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ error: Error?) {
        lock.lock(); self.error = error; lock.unlock()
    }

    func get() -> Error? {
        lock.lock(); defer { lock.unlock() }; return error
    }
}
