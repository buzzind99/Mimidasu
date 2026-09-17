import Foundation
import Security

/// Storage seam for provider API keys. The production conformer is the
/// Keychain; tests inject an in-memory (or unique-service) stand-in.
protocol SecureKeyStoring: Sendable {
    /// Stores (or overwrites) the key for a provider id.
    func saveKey(_ key: String, for providerID: String) throws(KeychainStoreError)

    /// Returns the stored key, or nil when none is configured. Read failures
    /// degrade to nil ("no key configured") and never echo secret material.
    func readKey(for providerID: String) -> String?

    /// Removes the key; deleting a missing key is a no-op.
    func deleteKey(for providerID: String)
}

/// Raw `SecItem*` calls behind `KeychainStore`. Seamable so the error-mapping
/// paths (an update or insert status other than success) can be exercised
/// without a locked keychain; production uses `SystemKeychainItemOperations`.
protocol KeychainItemOperations: Sendable {
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func add(_ query: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

/// Production `KeychainItemOperations` backed by the Security framework.
struct SystemKeychainItemOperations: KeychainItemOperations {
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func add(_ query: CFDictionary) -> OSStatus {
        SecItemAdd(query, nil)
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

/// Keychain-backed `SecureKeyStoring` for provider API keys.
///
/// Generic-password items keyed by (service, account = provider id), marked
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: device-only, never
/// iCloud-synced, non-exportable. Saves are add-or-update; reads swallow
/// OSStatus errors into nil so callers can only ever observe "key" or
/// "no key" — never a partial secret.
///
/// Invariants (enforced here): key
/// material never reaches UserDefaults, logs, error `localizedDescription`,
/// the pasteboard, or export files.
struct KeychainStore: SecureKeyStoring {
    /// Service name for the production app's translation keys.
    static let defaultService = "mimidasu.app.translation"

    private let service: String
    private let operations: any KeychainItemOperations

    /// - Parameters:
    ///   - service: override for tests, which must use unique per-test service
    ///     names so parallel suites never share items.
    ///   - operations: override for tests that need a raw status other than
    ///     success; defaults to the live Security framework.
    init(
        service: String = KeychainStore.defaultService,
        operations: any KeychainItemOperations = SystemKeychainItemOperations()
    ) {
        self.service = service
        self.operations = operations
    }

    func saveKey(_ key: String, for providerID: String) throws(KeychainStoreError) {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Update first: an existing item must be overwritten in place.
        let updateStatus = operations.update(baseQuery(for: providerID) as CFDictionary, attributes: attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError(status: updateStatus)
        }

        var addQuery = baseQuery(for: providerID)
        for (name, value) in attributes {
            addQuery[name] = value
        }
        let addStatus = operations.add(addQuery as CFDictionary)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError(status: addStatus)
        }
    }

    func readKey(for providerID: String) -> String? {
        var query = baseQuery(for: providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: AnyObject?
        let status = operations.copyMatching(query as CFDictionary, result: &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deleteKey(for providerID: String) {
        _ = operations.delete(baseQuery(for: providerID) as CFDictionary)
    }

    private func baseQuery(for providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]
    }
}

/// Surfaces a Keychain OSStatus without any item data attached.
struct KeychainStoreError: Error {
    let status: OSStatus
}
