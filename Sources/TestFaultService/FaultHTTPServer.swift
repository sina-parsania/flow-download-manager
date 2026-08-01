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
///   GET /fixtures/no-range-truncate -> probe behaves like no-range; plain GET
///                                    truncates mid-body (replacement failure)
///   GET /fixtures/range-ignored-200 -> alias of no-range (Range → HTTP 200 full body)
///   GET /fixtures/probe-200-ranges-ok -> `Range: bytes=0-0` → 200 full body, but
///                                    every other Range → 206 (CDN cache-miss shape)
///   GET /fixtures/signed-ranged  -> 2 MiB, honours Range; used with a
///                                    `?expires=&sig=` query (probe-skipping URL
///                                    that is nonetheless range-capable)
///   GET /fixtures/range-shifted     -> 206 with a shifted Content-Range interval
///   GET /fixtures/range-malformed-cr -> 206 with malformed Content-Range
///   GET /fixtures/range-wrong-total -> 206 with correct slice but wrong total
///   GET /fixtures/range-error-body  -> 403 with a body sized like the requested range
///   GET /fixtures/range-forbidden -> 403 when Range is present; 200 full body otherwise
///   GET /fixtures/once           -> Range → 403 (no consume); first plain GET
///                                    returns the body and consumes the token;
///                                    later GETs → 403
///   GET /fixtures/changing-etag  -> 200 with an ETag that changes each request
///   GET /fixtures/truncated      -> Content-Length larger than the bytes sent
///   GET /fixtures/large          -> 2 MiB ranged body (real multi-segment plans)
///   GET /fixtures/throughput     -> ranged body with a per-connection rate cap;
///                                    `?size=&kbps=&slowFirst=&slowKbps=&rtt=&loss=`
///                                    — throughput / RTT / loss fixture
///   GET /fixtures/flaky          -> ranged body, but the first `drops`
///                                    connections hang up mid-body;
///                                    `?size=&drops=` — the bad-link fixture
///   GET /fixtures/redirect/metadata-hop      -> 302 with hop-only metadata
///   GET /fixtures/redirect/metadata-hop2     -> second hop in a redirect chain
///   GET /fixtures/redirect/metadata-chain    -> 302 through hop2 to terminal
///   GET /fixtures/redirect/metadata-terminal -> 200 terminal metadata only
///   GET /fixtures/redirect/same-origin       -> 302 to capture (same host)
///   GET /fixtures/redirect/cross?port=<n>    -> 302 to another loopback port
///   GET /fixtures/redirect/capture           -> records request header names
///   GET /fixtures/rate-limited   -> 429 with `Retry-After: 7` (delta-seconds)
///   GET /fixtures/rate-limited-http-date -> 429 with an HTTP-date `Retry-After`,
///                                    deliberately left unparsed
///   GET /status/<code>           -> responds with that status code
///   POST /control/reset          -> clears request log + counters
///   GET  /control/logs           -> newline-delimited request log
public final class FaultHTTPServer: @unchecked Sendable {
    /// Fixed fixture payload (deterministic bytes).
    public static let fixtureBody = Data((0 ..< 4096).map { UInt8($0 % 251) })

    /// 2 MiB body served from `/fixtures/large`. Sized to land in
    /// `preferredSegmentCount`'s 1 MiB…8 MiB band so segmented transfers under
    /// test really run more than one range.
    public static let largeBody = Data((0 ..< (2 * 1024 * 1024)).map { UInt8($0 % 251) })

    /// 1.5 MiB — deliberately inside the band where a 1 MiB opening chunk leaves a
    /// remainder **below** `preferredSegmentCount`'s 1 MiB floor, so the remainder
    /// tiles to a single connection. `largeBody` (2 MiB) leaves exactly 1 MiB and
    /// tiles to 2, so it cannot reach this case at all.
    public static let awkwardRemainderBody = Data(
        (0 ..< (1536 * 1024)).map { UInt8($0 % 251) }
    )
    public static let strongETag = "\"dm-fixture-v1\""

    private let queue = DispatchQueue(label: "org.downloadmanager.local.faultservice")
    private let lock = NSLock()
    private var listener: NWListener?
    private var requestLog: [String] = []
    /// Header names observed per capture path (`path|Header-Name`), never values.
    private var headerNamesLog: [String] = []
    private var etagCounter = 0
    /// Successful body responses served by `/fixtures/once`.
    private var onceHits = 0
    private var rangedRequestsObserved = 0
    /// Generated throughput bodies, cached by size so a benchmark that issues
    /// many ranged requests does not rebuild the same buffer each time.
    private var throughputBodies: [Int: Data] = [:]
    /// Connections served by `/fixtures/throughput`, so `slowFirst` and
    /// `dropFirst` can deterministically pick which connections are affected.
    private var throughputConnections = 0
    private var throughputConnectionAttempts = 0
    private var throughputConnectionsDropped = 0
    /// Connections served by `/fixtures/flaky`, so the first N can be dropped
    /// deterministically.
    private var flakyConnections = 0

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
        headerNamesLog.removeAll()
        etagCounter = 0
        onceHits = 0
        rangedRequestsObserved = 0
        throughputConnections = 0
        throughputConnectionAttempts = 0
        throughputConnectionsDropped = 0
        flakyConnections = 0
        lock.unlock()
    }

    public func logs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    /// Requests that carried a `Range` header (probe observability for tests).
    public func rangedRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return rangedRequestsObserved
    }

    /// Connections opened by `/fixtures/throughput` since the last reset.
    public func throughputConnectionAttemptCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return throughputConnectionAttempts
    }

    /// Connections intentionally dropped mid-body by `/fixtures/throughput`.
    public func throughputConnectionsDroppedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return throughputConnectionsDropped
    }

    /// Canonical header names recorded for @c path on `/fixtures/redirect/capture`.
    public func recordedHeaderNames(on path: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(path)|"
        return headerNamesLog.compactMap { entry in
            guard entry.hasPrefix(prefix) else { return nil }
            return String(entry.dropFirst(prefix.count))
        }
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
        let rawTarget = String(parts[1])
        // Keep query values for fixtures that depend on them (throughput/flaky)
        // while still routing on a stable path stem.
        // Strip the query so `/fixtures/large?X-Amz-Signature=…` still hits the
        // ranged fixture — signed-URL heuristics are tested against the full URL.
        let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
        let headerNames = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }

        lock.lock()
        requestLog.append("\(method) \(rawTarget)")
        if rangeHeader != nil { rangedRequestsObserved += 1 }
        if path == "/fixtures/redirect/capture" {
            for name in headerNames {
                headerNamesLog.append("\(path)|\(name)")
            }
        }
        lock.unlock()

        route(
            method: method,
            path: path,
            queryPath: rawTarget,
            rangeHeader: rangeHeader,
            headerNames: headerNames,
            on: connection
        )
    }

    private func route(
        method: String,
        path: String,
        queryPath: String,
        rangeHeader: String?,
        headerNames _: [String],
        on connection: NWConnection
    ) {
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

        case "/fixtures/large":
            // Big enough that `preferredSegmentCount` actually picks a
            // multi-segment plan; `/fixtures/ok` is 4 KiB and always tiles to 1.
            serveFixture(
                body: Self.largeBody,
                rangeHeader: rangeHeader,
                acceptRanges: true,
                etag: Self.strongETag,
                on: connection
            )

        case "/fixtures/rate-limited":
            // 429 with the delta-seconds `Retry-After` a real rate limiter sends.
            // The engine must come back when the server said, not when its own
            // backoff curve happens to land.
            send(
                status: 429,
                reason: "Too Many Requests",
                headers: ["Retry-After": "7"],
                body: Data("slow down".utf8),
                on: connection
            )

        case "/fixtures/rate-limited-http-date":
            // Legal but unparsed on purpose: misreading a date as a delay is worse
            // than falling back to our own backoff.
            send(
                status: 429,
                reason: "Too Many Requests",
                headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"],
                body: Data("slow down".utf8),
                on: connection
            )

        case "/fixtures/signed-ranged-awkward":
            // 1.5 MiB: the opening chunk takes 1 MiB and leaves 0.5 MiB, which
            // tiles to a single connection. Guards against calling that "done".
            serveFixture(
                body: Self.awkwardRemainderBody,
                rangeHeader: rangeHeader,
                acceptRanges: true,
                etag: Self.strongETag,
                on: connection
            )

        case "/fixtures/signed-ranged":
            // Expiring-signature CDN shape: served only with `sig=`/`expires=` in
            // the query (so `looksLikeFragileSignedURL` matches and the separate
            // probe is skipped), but ranges are honoured normally. This is the
            // user-reported host's shape — an expiring signature is re-fetchable
            // until it expires, unlike a one-shot token.
            serveFixture(
                body: Self.largeBody,
                rangeHeader: rangeHeader,
                acceptRanges: true,
                etag: Self.strongETag,
                on: connection
            )

        case "/fixtures/probe-200-ranges-ok":
            // CDN cache-miss shape: the `Range: bytes=0-0` probe is answered 200
            // with the full body, but real ranged GETs are honoured with 206.
            // Cloudflare does exactly this — same URL, MISS then HIT — and reading
            // the probe's 200 as "no ranges" pinned the whole download to one
            // connection. Keyed on the probe's own range so the test is
            // deterministic rather than dependent on request ordering.
            serveFixture(
                body: Self.largeBody,
                rangeHeader: rangeHeader == "bytes=0-0" ? nil : rangeHeader,
                acceptRanges: rangeHeader != "bytes=0-0",
                etag: Self.strongETag,
                on: connection
            )

        case "/fixtures/no-range":
            // Ignores Range: always returns the full 200 body.
            serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)

        case "/fixtures/no-range-large":
            // Same as no-range but 2 MiB — a capped probe must not pull the lot.
            serveFixture(
                body: Self.largeBody,
                rangeHeader: nil,
                acceptRanges: false,
                etag: Self.strongETag,
                on: connection
            )

        case "/fixtures/no-range-truncate":
            // Ranged probe succeeds like no-range; a plain GET truncates so a
            // replacement download can fail without touching the original partial.
            if rangeHeader != nil {
                serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)
            } else {
                let body = Self.fixtureBody.prefix(1024)
                var headers = "HTTP/1.1 200 OK\r\n"
                headers += "Content-Length: \(Self.fixtureBody.count)\r\n"
                headers += "ETag: \(Self.strongETag)\r\n"
                headers += "Connection: close\r\n\r\n"
                var response = Data(headers.utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }

        case "/fixtures/range-ignored-200":
            serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)

        case "/fixtures/range-shifted":
            serveShiftedRange(rangeHeader: rangeHeader, on: connection)

        case "/fixtures/range-malformed-cr":
            serveMalformedContentRange(rangeHeader: rangeHeader, on: connection)

        case "/fixtures/range-wrong-total":
            serveWrongTotalContentRange(rangeHeader: rangeHeader, on: connection)

        case "/fixtures/range-error-body":
            serveRangeErrorBody(rangeHeader: rangeHeader, on: connection)

        case "/fixtures/range-forbidden":
            // Range probe rejected; plain GET still delivers the file.
            if rangeHeader != nil {
                send(
                    status: 403,
                    reason: "Forbidden",
                    body: Data(#"{"detail":"range not allowed"}"#.utf8),
                    on: connection
                )
            } else {
                serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)
            }

        case "/fixtures/once":
            // One-shot token. A ranged probe must not consume it — reject Range
            // without burning so a plain GET can still succeed.
            if rangeHeader != nil {
                send(
                    status: 403,
                    reason: "Forbidden",
                    body: Data(#"{"detail":"range not allowed"}"#.utf8),
                    on: connection
                )
                return
            }
            lock.lock()
            let alreadyConsumed = onceHits > 0
            if !alreadyConsumed { onceHits += 1 }
            lock.unlock()
            if alreadyConsumed {
                send(
                    status: 403,
                    reason: "Forbidden",
                    body: Data(#"{"detail":"token consumed"}"#.utf8),
                    on: connection
                )
            } else {
                serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)
            }

        case "/fixtures/changing-etag":
            lock.lock(); etagCounter += 1; let counter = etagCounter; lock.unlock()
            serveFixture(
                rangeHeader: rangeHeader,
                acceptRanges: true,
                etag: "\"changing-\(counter)\"",
                on: connection
            )

        case "/fixtures/redirect/metadata-hop":
            sendRedirect(
                to: "/fixtures/redirect/metadata-terminal",
                extraHeaders: [
                    "ETag": "\"hop-only-etag\"",
                    "Content-Type": "application/x-hop",
                    "Content-Disposition": "attachment; filename=\"hop.bin\"",
                    "Accept-Ranges": "none"
                ],
                on: connection
            )

        case "/fixtures/redirect/metadata-hop2":
            sendRedirect(
                to: "/fixtures/redirect/metadata-terminal",
                extraHeaders: [
                    "ETag": "\"second-hop-etag\"",
                    "Content-Type": "application/x-second-hop",
                    "Last-Modified": "Mon, 01 Jan 1990 00:00:00 GMT"
                ],
                on: connection
            )

        case "/fixtures/redirect/metadata-chain":
            sendRedirect(to: "/fixtures/redirect/metadata-hop2", on: connection)

        case "/fixtures/redirect/metadata-terminal":
            serveFixture(
                rangeHeader: rangeHeader,
                acceptRanges: true,
                etag: "\"terminal-only\"",
                contentType: "application/octet-stream",
                on: connection
            )

        case "/fixtures/redirect/same-origin":
            sendRedirect(to: "/fixtures/redirect/capture", on: connection)

        case "/fixtures/redirect/cross":
            let query = Self.queryItems(queryPath)
            guard let port = query["port"], !port.isEmpty else {
                send(status: 400, reason: "Bad Request", body: Data(), on: connection)
                return
            }
            sendRedirect(
                to: "http://127.0.0.1:\(port)/fixtures/redirect/capture",
                on: connection
            )

        case "/fixtures/redirect/capture":
            serveFixture(
                rangeHeader: nil,
                acceptRanges: false,
                etag: Self.strongETag,
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
            if path.hasPrefix("/fixtures/flaky") {
                serveFlaky(path: queryPath, rangeHeader: rangeHeader, on: connection)
            } else if path.hasPrefix("/fixtures/throughput") {
                serveThroughput(path: queryPath, rangeHeader: rangeHeader, on: connection)
            } else if path.hasPrefix("/status/"), let code = Int(path.dropFirst("/status/".count)) {
                send(status: code, reason: reason(for: code), body: Data("status \(code)".utf8), on: connection)
            } else {
                send(status: 404, reason: "Not Found", body: Data(), on: connection)
            }
        }
    }

    // MARK: throughput fixture

    /// `GET
    /// /fixtures/throughput?size=<bytes>&kbps=<cap>&slowFirst=<n>&slowKbps=<cap>&rtt=<ms>&loss=<percent>&dropFirst=<n>`
    ///
    /// Range-capable body of `size` bytes. `kbps` caps each connection's send
    /// rate; the first `slowFirst` connections are capped at `slowKbps` instead.
    /// The per-connection cap is what makes segmented throughput measurable:
    /// without it a loopback transfer finishes instantly and parallelism is
    /// invisible. `slowFirst` reproduces the straggler that dominates the tail.
    ///
    /// `rtt` delays the first byte of every connection by that many milliseconds
    /// (one-way), modelling high-latency links. `dropFirst` hangs up after roughly
    /// one third of the payload on the first N connections — the deterministic
    /// correctness schedule. `loss` applies the same mid-stream drop using a
    /// seeded draw per connection index for exploratory curves only.
    private func serveThroughput(path: String, rangeHeader: String?, on connection: NWConnection) {
        let query = Self.queryItems(path)
        let size = query["size"].flatMap(Int.init) ?? (8 * 1024 * 1024)
        let kbps = query["kbps"].flatMap(Int.init) ?? 0
        let slowFirst = query["slowFirst"].flatMap(Int.init) ?? 0
        let slowKbps = query["slowKbps"].flatMap(Int.init) ?? 0
        let rttMs = max(0, query["rtt"].flatMap(Int.init) ?? 0)
        let dropFirst = max(0, query["dropFirst"].flatMap(Int.init) ?? 0)
        // Fractional percents are intentional (TASK 2: 0.1% / 1%). A connection
        // drops when a seeded draw in [0, 100) lands below `loss`.
        let lossPercent = min(100.0, max(0.0, query["loss"].flatMap(Double.init) ?? 0))
        guard size > 0, size <= 512 * 1024 * 1024 else {
            send(status: 400, reason: "Bad Request", body: Data(), on: connection)
            return
        }

        lock.lock()
        let body: Data
        if let cached = throughputBodies[size] {
            body = cached
        } else {
            body = Data((0 ..< size).map { UInt8($0 % 251) })
            throughputBodies[size] = body
        }
        let index = throughputConnections
        throughputConnections += 1
        throughputConnectionAttempts += 1
        lock.unlock()

        let rate = index < slowFirst ? slowKbps : kbps
        let dropMidStream: Bool = if dropFirst > 0 {
            index < dropFirst
        } else if lossPercent > 0 {
            Self.seededLossDraw(connectionIndex: index) < lossPercent
        } else {
            false
        }
        if dropMidStream {
            lock.lock()
            throughputConnectionsDropped += 1
            lock.unlock()
        }

        let range = rangeHeader.flatMap { Self.parseRange($0, total: body.count) }
        let payload = range.map { body.subdata(in: $0) } ?? body
        var headers = range.map {
            "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Range: bytes \($0.lowerBound)-\($0.upperBound - 1)/\(body.count)\r\n"
        } ?? "HTTP/1.1 200 OK\r\n"
        headers += "Content-Length: \(payload.count)\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "ETag: \(Self.strongETag)\r\n"
        headers += "Connection: close\r\n\r\n"

        let hangUpAfter: Int? = dropMidStream ? max(1, payload.count / 3) : nil
        let headerData = Data(headers.utf8)
        let beginSend: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            connection.send(content: headerData, completion: .contentProcessed { _ in
                self.sendThrottled(
                    payload,
                    from: 0,
                    kbps: rate,
                    hangUpAfter: hangUpAfter,
                    on: connection
                )
            })
        }
        if rttMs > 0 {
            queue.asyncAfter(deadline: .now() + .milliseconds(rttMs), execute: beginSend)
        } else {
            beginSend()
        }
    }

    /// Sends `body` in chunks, pacing each chunk so the connection averages
    /// `kbps` kilobytes/second. `kbps <= 0` sends at full speed.
    /// When `hangUpAfter` is set, the connection closes once that many bytes
    /// have been written — modelling a mid-transfer drop without rewriting the
    /// Content-Length (the client sees a short read).
    private func sendThrottled(
        _ body: Data,
        from offset: Int,
        kbps: Int,
        hangUpAfter: Int? = nil,
        on connection: NWConnection
    ) {
        if let hangUpAfter, offset >= hangUpAfter {
            connection.cancel()
            return
        }
        guard offset < body.count else {
            connection.cancel()
            return
        }
        let chunkSize = kbps > 0 ? min(64 * 1024, kbps * 1024) : 256 * 1024
        let uncappedEnd = min(offset + chunkSize, body.count)
        let end = hangUpAfter.map { min(uncappedEnd, $0) } ?? uncappedEnd
        let chunk = body.subdata(in: offset ..< end)
        let delay: TimeInterval = kbps > 0 ? Double(chunk.count) / Double(kbps * 1024) : 0
        let nextOffset = end

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            if delay > 0 {
                queue.asyncAfter(deadline: .now() + delay) {
                    self.sendThrottled(body, from: nextOffset, kbps: kbps, hangUpAfter: hangUpAfter, on: connection)
                }
            } else {
                sendThrottled(body, from: nextOffset, kbps: kbps, hangUpAfter: hangUpAfter, on: connection)
            }
        })
    }

    /// `GET /fixtures/flaky?size=<bytes>&drops=<n>`
    ///
    /// Range-capable, but the first `drops` connections send only part of the
    /// body and then close abruptly — a mid-transfer disconnect, the defining
    /// behaviour of a bad link. Later connections behave normally, so a client
    /// that retries and resumes correctly finishes with the right bytes and one
    /// that does not, does not.
    private func serveFlaky(path: String, rangeHeader: String?, on connection: NWConnection) {
        let query = Self.queryItems(path)
        let size = query["size"].flatMap(Int.init) ?? (2 * 1024 * 1024)
        let drops = query["drops"].flatMap(Int.init) ?? 2
        guard size > 0, size <= 64 * 1024 * 1024 else {
            send(status: 400, reason: "Bad Request", body: Data(), on: connection)
            return
        }

        lock.lock()
        let body: Data
        if let cached = throughputBodies[size] {
            body = cached
        } else {
            body = Data((0 ..< size).map { UInt8($0 % 251) })
            throughputBodies[size] = body
        }
        let index = flakyConnections
        flakyConnections += 1
        lock.unlock()

        let range = rangeHeader.flatMap { Self.parseRange($0, total: body.count) }
        let payload = range.map { body.subdata(in: $0) } ?? body
        var headers = range.map {
            "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Range: bytes \($0.lowerBound)-\($0.upperBound - 1)/\(body.count)\r\n"
        } ?? "HTTP/1.1 200 OK\r\n"
        headers += "Content-Length: \(payload.count)\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "ETag: \(Self.strongETag)\r\n"
        headers += "Connection: close\r\n\r\n"

        // Declare the full length, then hang up early. The client sees a short
        // read, exactly as it would on a dropped link.
        let truncated = index < drops
        let toSend = truncated ? payload.prefix(max(1, payload.count / 3)) : payload
        var response = Data(headers.utf8)
        response.append(toSend)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func queryItems(_ path: String) -> [String: String] {
        guard let mark = path.firstIndex(of: "?") else { return [:] }
        var items: [String: String] = [:]
        for pair in path[path.index(after: mark)...].split(separator: "&") {
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            items[String(halves[0])] = String(halves[1])
        }
        return items
    }

    /// Deterministic pseudo-random draw in `[0, 100)` for exploratory `loss=`
    /// curves. Correctness tests must use `dropFirst=` instead.
    static func seededLossDraw(connectionIndex: Int) -> Double {
        let mixed = UInt64(bitPattern: Int64(connectionIndex &+ 0x9E37_79B9))
        let scaled = (mixed &* 0xBF58_476D_1CE4_E5B9) >> 32
        return Double(scaled % 10000) / 100.0
    }

    private func serveShiftedRange(rangeHeader: String?, on connection: NWConnection) {
        let body = Self.fixtureBody
        guard let rangeHeader, let requested = Self.parseRange(rangeHeader, total: body.count) else {
            serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)
            return
        }
        let shift = min(requested.count, max(1, body.count / 4))
        let shiftedStart = min(requested.lowerBound + shift, body.count - requested.count)
        let shiftedEnd = shiftedStart + requested.count
        guard shiftedEnd <= body.count else {
            serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)
            return
        }
        let slice = body.subdata(in: shiftedStart ..< shiftedEnd)
        var headers = "HTTP/1.1 206 Partial Content\r\n"
        headers += "Content-Range: bytes \(shiftedStart)-\(shiftedEnd - 1)/\(body.count)\r\n"
        headers += "Content-Length: \(slice.count)\r\n"
        headers += "Accept-Ranges: bytes\r\n"
        headers += "ETag: \(Self.strongETag)\r\n"
        headers += "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(slice)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func serveMalformedContentRange(rangeHeader: String?, on connection: NWConnection) {
        let body = Self.fixtureBody
        guard let rangeHeader, let range = Self.parseRange(rangeHeader, total: body.count) else {
            serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)
            return
        }
        let slice = body.subdata(in: range)
        var headers = "HTTP/1.1 206 Partial Content\r\n"
        headers += "Content-Range: not-bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)\r\n"
        headers += "Content-Length: \(slice.count)\r\n"
        headers += "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(slice)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func serveWrongTotalContentRange(rangeHeader: String?, on connection: NWConnection) {
        let body = Self.fixtureBody
        guard let rangeHeader, let range = Self.parseRange(rangeHeader, total: body.count) else {
            serveFixture(rangeHeader: nil, acceptRanges: false, etag: Self.strongETag, on: connection)
            return
        }
        let slice = body.subdata(in: range)
        let wrongTotal = range.upperBound - 1
        var headers = "HTTP/1.1 206 Partial Content\r\n"
        headers += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(wrongTotal)\r\n"
        headers += "Content-Length: \(slice.count)\r\n"
        headers += "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(slice)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func serveRangeErrorBody(rangeHeader: String?, on connection: NWConnection) {
        let body = Self.fixtureBody
        guard let rangeHeader, let range = Self.parseRange(rangeHeader, total: body.count) else {
            send(status: 403, reason: "Forbidden", body: Data("forbidden".utf8), on: connection)
            return
        }
        let slice = body.subdata(in: range)
        send(status: 403, reason: "Forbidden", body: slice, on: connection)
    }

    private func serveFixture(
        body: Data? = nil,
        rangeHeader: String?,
        acceptRanges: Bool,
        etag: String,
        contentType: String? = nil,
        on connection: NWConnection
    ) {
        let body = body ?? Self.fixtureBody
        if acceptRanges, let rangeHeader, let range = Self.parseRange(rangeHeader, total: body.count) {
            let slice = body.subdata(in: range)
            var headers = "HTTP/1.1 206 Partial Content\r\n"
            headers += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)\r\n"
            headers += "Content-Length: \(slice.count)\r\n"
            if acceptRanges { headers += "Accept-Ranges: bytes\r\n" }
            if let contentType { headers += "Content-Type: \(contentType)\r\n" }
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
        if let contentType { headers += "Content-Type: \(contentType)\r\n" }
        headers += "ETag: \(etag)\r\n"
        headers += "Connection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendRedirect(
        to location: String,
        extraHeaders: [String: String] = [:],
        on connection: NWConnection
    ) {
        var headers = "HTTP/1.1 302 Found\r\n"
        headers += "Location: \(location)\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headers += "\(name): \(value)\r\n"
        }
        headers += "Content-Length: 0\r\n"
        headers += "Connection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func send(
        status: Int,
        reason: String,
        headers extra: [String: String] = [:],
        body: Data,
        on connection: NWConnection
    ) {
        var headers = "HTTP/1.1 \(status) \(reason)\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        // Sorted so a fixture's bytes are identical run to run.
        for (name, value) in extra.sorted(by: { $0.key < $1.key }) {
            headers += "\(name): \(value)\r\n"
        }
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
