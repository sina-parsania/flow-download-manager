// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import EngineAgent
import Foundation
import XCTest
import XPCContracts

/// Test-only validator that accepts any connection, used to isolate transport
/// behavior from identity validation. Not part of any shipping module.
private struct AcceptAllValidator: ClientIdentityValidator {
    func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        true
    }
}

/// Resumes a continuation exactly once from any of several racing callbacks
/// (reply error, invalidation, interruption).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<T, Never>
    init(_ cont: CheckedContinuation<T, Never>) {
        self.cont = cont
    }

    func resume(_ value: T) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { cont.resume(returning: value) }
    }
}

/// XPC handshake, health, idempotency, identity and reconnect behavior over an
/// in-process anonymous listener (`04-domain-and-data-contracts.md` §9,
/// `05-quality-testing-release-gates.md` §2 Component tests).
final class XPCRoundTripTests: XCTestCase {
    private func makeServices() -> EngineServices {
        EngineServices(
            engineBuild: "test-build",
            databaseVersion: SchemaVersions.database,
            isDatabaseOpen: { true },
            startDate: Date(timeIntervalSinceNow: -10)
        )
    }

    private func makeControl(
        validator: any ClientIdentityValidator = AcceptAllValidator()
    ) throws -> (control: EngineControlProtocol, teardown: () -> Void) {
        let listener = NSXPCListener.anonymous()
        let delegate = EngineServiceListener(validator: validator, services: makeServices())
        listener.delegate = delegate
        listener.resume()

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = EngineControlInterface.make()
        connection.resume()

        guard let control = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? EngineControlProtocol else {
            connection.invalidate()
            listener.invalidate()
            throw XPCTestError.proxyUnavailable
        }
        return (control, {
            connection.invalidate()
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        })
    }

    private enum XPCTestError: Error { case proxyUnavailable }

    private func handshake(_ control: EngineControlProtocol, build: String = "test") async throws -> ServerHello? {
        try await withCheckedThrowingContinuation { cont in
            let hello = ClientHello(
                protocolVersion: SchemaVersions.xpcProtocol,
                clientBuild: build, clientRole: .app, capabilities: ["health"]
            )
            control.handshake(hello) { serverHello, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: serverHello) }
            }
        }
    }

    private func health(_ control: EngineControlProtocol, _ requestID: String) async throws -> EngineHealthSnapshot? {
        try await withCheckedThrowingContinuation { cont in
            control.healthStatus(requestID: requestID) { snapshot, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: snapshot) }
            }
        }
    }

    // MARK: happy path

    func testHandshakeThenHealthRoundTrip() async throws {
        let (control, teardown) = try makeControl()
        defer { teardown() }

        let serverHello = try await handshake(control)
        XCTAssertEqual(serverHello?.acceptedVersion, SchemaVersions.xpcProtocol)
        XCTAssertEqual(serverHello?.engineBuild, "test-build")
        XCTAssertEqual(serverHello?.databaseVersion, SchemaVersions.database)

        let requestID = UUID().uuidString
        let snapshot = try await health(control, requestID)
        XCTAssertEqual(snapshot?.requestID, requestID)
        XCTAssertEqual(snapshot?.databaseOpen, true)
        XCTAssertGreaterThan(snapshot?.uptimeSeconds ?? 0, 0)
    }

    // MARK: gating & validation

    func testHealthBeforeHandshakeRejected() async throws {
        let (control, teardown) = try makeControl()
        defer { teardown() }
        let error: NSError? = await withCheckedContinuation { cont in
            control.healthStatus(requestID: UUID().uuidString) { _, error in cont.resume(returning: error) }
        }
        XCTAssertEqual(error?.domain, XPCErrorDomain)
        XCTAssertEqual(error?.code, XPCErrorCode.handshakeRequired.rawValue)
    }

    func testInvalidRequestIDRejected() async throws {
        let (control, teardown) = try makeControl()
        defer { teardown() }
        _ = try await handshake(control)
        let error: NSError? = await withCheckedContinuation { cont in
            control.healthStatus(requestID: "not-a-uuid") { _, error in cont.resume(returning: error) }
        }
        XCTAssertEqual(error?.code, XPCErrorCode.invalidPayload.rawValue)
    }

    func testUnsupportedProtocolVersionRejected() async throws {
        let (control, teardown) = try makeControl()
        defer { teardown() }
        let error: NSError? = await withCheckedContinuation { cont in
            let hello = ClientHello(protocolVersion: 999, clientBuild: "x", clientRole: .app, capabilities: [])
            control.handshake(hello) { _, error in cont.resume(returning: error) }
        }
        XCTAssertEqual(error?.code, XPCErrorCode.unsupportedProtocolVersion.rawValue)
    }

    // MARK: idempotency

    func testDuplicateRequestIDReplaysSameSnapshot() async throws {
        let (control, teardown) = try makeControl()
        defer { teardown() }
        _ = try await handshake(control)
        let requestID = UUID().uuidString
        let first = try await health(control, requestID)
        let second = try await health(control, requestID)
        // Idempotent replay: identical snapshot (including uptime) is returned.
        XCTAssertEqual(first?.requestID, second?.requestID)
        XCTAssertEqual(first?.uptimeSeconds, second?.uptimeSeconds)
    }

    // MARK: identity

    func testUnauthorizedClientRejected() async {
        let listener = NSXPCListener.anonymous()
        // A requirement no test-runner identity can satisfy → fail closed.
        let validator = CodeSigningIdentityValidator(
            requirement: "identifier \"org.downloadmanager.local.NoSuchClient\""
        )
        let delegate = EngineServiceListener(validator: validator, services: makeServices())
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = EngineControlInterface.make()

        let rejected: Bool = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            connection.invalidationHandler = { once.resume(true) }
            connection.interruptionHandler = { once.resume(true) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(true) }
            let hello = ClientHello(
                protocolVersion: SchemaVersions.xpcProtocol, clientBuild: "x",
                clientRole: .app, capabilities: []
            )
            (proxy as? EngineControlProtocol)?.handshake(hello) { _, error in
                once.resume(error != nil)
            }
        }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
        XCTAssertTrue(rejected, "an unauthorized client must be rejected")
    }

    // MARK: reconnect

    func testReconnectAfterInvalidation() async throws {
        let listener = NSXPCListener.anonymous()
        let delegate = EngineServiceListener(validator: AcceptAllValidator(), services: makeServices())
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate(); withExtendedLifetime(delegate) {} }

        let first = NSXPCConnection(listenerEndpoint: listener.endpoint)
        first.remoteObjectInterface = EngineControlInterface.make()
        first.resume()
        let control1 = try XCTUnwrap(first.remoteObjectProxyWithErrorHandler { _ in } as? EngineControlProtocol)
        _ = try await handshake(control1)
        first.invalidate()

        // Reconnect to the same listener endpoint and handshake again.
        let second = NSXPCConnection(listenerEndpoint: listener.endpoint)
        second.remoteObjectInterface = EngineControlInterface.make()
        second.resume()
        defer { second.invalidate() }
        let control2 = try XCTUnwrap(second.remoteObjectProxyWithErrorHandler { _ in } as? EngineControlProtocol)
        let serverHello = try await handshake(control2)
        XCTAssertEqual(serverHello?.acceptedVersion, SchemaVersions.xpcProtocol)
    }
}
