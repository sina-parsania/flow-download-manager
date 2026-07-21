// SPDX-License-Identifier: GPL-3.0-or-later

import SharedSecurity
import XCTest

final class SecretStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemorySecretStore()
        let secret = Data("hunter2".utf8)
        let ref = try store.store(secret, account: "user@example.test")
        XCTAssertEqual(try store.readSecret(persistentRef: ref), secret)
        try store.deleteSecret(persistentRef: ref)
        XCTAssertThrowsError(try store.readSecret(persistentRef: ref)) { error in
            XCTAssertEqual(error as? SecretStoreError, .notFound)
        }
    }

    func testInMemoryDeleteIsIdempotent() throws {
        let store = InMemorySecretStore()
        let ref = try store.store(Data("x".utf8), account: "a")
        try store.deleteSecret(persistentRef: ref)
        XCTAssertNoThrow(try store.deleteSecret(persistentRef: ref))
    }

    func testKeychainStoreRoundTrip() throws {
        // Exercises the real Keychain path on a developer machine. Uses a unique
        // service so runs never collide; cleans up after itself.
        let service = "org.downloadmanager.local.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let secret = Data("s3cr3t-token".utf8)

        let ref = try store.store(secret, account: "test-account")
        defer { try? store.deleteSecret(persistentRef: ref) }

        XCTAssertEqual(try store.readSecret(persistentRef: ref), secret)

        // Overwriting the same account replaces the value.
        let secret2 = Data("rotated".utf8)
        let ref2 = try store.store(secret2, account: "test-account")
        defer { try? store.deleteSecret(persistentRef: ref2) }
        XCTAssertEqual(try store.readSecret(persistentRef: ref2), secret2)

        try store.deleteSecret(persistentRef: ref2)
        XCTAssertThrowsError(try store.readSecret(persistentRef: ref2))
    }
}

final class SecretStringTests: XCTestCase {
    func testNeverPrintsContents() {
        let secret = SecretString("password123")
        XCTAssertEqual(secret.description, "<redacted>")
        XCTAssertEqual("\(secret)", "<redacted>")
        XCTAssertEqual(String(reflecting: secret), "<redacted>")
        XCTAssertFalse("\(secret)".contains("password"))
    }

    func testRevealReturnsValue() {
        XCTAssertEqual(SecretString("abc").reveal(), "abc")
    }

    func testEquality() {
        XCTAssertEqual(SecretString("same"), SecretString("same"))
        XCTAssertNotEqual(SecretString("a"), SecretString("b"))
        XCTAssertNotEqual(SecretString("short"), SecretString("longer"))
    }
}
