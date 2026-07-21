// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// In-memory `SecretStore` for previews and deterministic tests. Never used in
/// production; secrets are held only in process memory for the test's lifetime.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data: Data] = [:]

    public init() {}

    public func store(_ secret: Data, account: String) throws -> Data {
        let ref = Data(UUID().uuidString.utf8)
        lock.lock()
        storage[ref] = secret
        lock.unlock()
        return ref
    }

    public func readSecret(persistentRef: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let secret = storage[persistentRef] else { throw SecretStoreError.notFound }
        return secret
    }

    public func deleteSecret(persistentRef: Data) throws {
        lock.lock()
        storage[persistentRef] = nil
        lock.unlock()
    }
}
