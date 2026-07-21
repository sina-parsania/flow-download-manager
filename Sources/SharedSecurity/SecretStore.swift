// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security

/// Persistent secret storage. Secrets live only here (the Keychain); the database
/// stores an opaque persistent reference and never the secret itself
/// (`02-architecture.md` §18.4, `06-licensing-security-privacy.md` §4). The
/// protocol is a seam so callers and tests can substitute an in-memory store.
public protocol SecretStore: Sendable {
    /// Store `secret` for `account`, replacing any existing item, returning an
    /// opaque persistent reference suitable for storage in a nonsecret column.
    func store(_ secret: Data, account: String) throws -> Data

    /// Read the secret for a persistent reference. Throws if absent.
    func readSecret(persistentRef: Data) throws -> Data

    /// Delete the secret for a persistent reference. Idempotent.
    func deleteSecret(persistentRef: Data) throws
}

public enum SecretStoreError: Error, Equatable {
    case osStatus(OSStatus)
    case unexpectedResult
    case notFound
}

/// Production `SecretStore` backed by the macOS Keychain (generic password items).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func store(_ secret: Data, account: String) throws -> Data {
        // Replace any existing item for (service, account) first.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnPersistentRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemAdd(addQuery as CFDictionary, &result)
        guard status == errSecSuccess else { throw SecretStoreError.osStatus(status) }
        guard let ref = result as? Data else { throw SecretStoreError.unexpectedResult }
        return ref
    }

    public func readSecret(persistentRef: Data) throws -> Data {
        let query: [String: Any] = [
            kSecValuePersistentRef as String: persistentRef,
            kSecReturnData as String: true
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status != errSecItemNotFound else { throw SecretStoreError.notFound }
        guard status == errSecSuccess else { throw SecretStoreError.osStatus(status) }
        guard let data = out as? Data else { throw SecretStoreError.unexpectedResult }
        return data
    }

    public func deleteSecret(persistentRef: Data) throws {
        let query: [String: Any] = [kSecValuePersistentRef as String: persistentRef]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.osStatus(status)
        }
    }
}
