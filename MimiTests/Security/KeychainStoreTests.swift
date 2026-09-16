import Foundation
@testable import Mimi
import Security
import Testing

/// Tests `KeychainStore` against the real Keychain, with a unique per-test
/// service name so parallel test functions never share items (Swift Testing
/// runs in parallel; the store is the unit under test, not the keychain's
/// cross-item behavior). Each test cleans up its own service via `defer`.
///
/// These tests need an unlocked, interactive login keychain: a locked keychain
/// or a headless runner without keychain access surfaces
/// `errSecInteractionNotAllowed`/`errSecMissingEntitlement` from
/// `SecItemUpdate`/`SecItemAdd` and fails the suite.
@Suite("KeychainStore")
struct KeychainStoreTests {

    private let providerID = "test-provider"

    // MARK: - Helpers

    /// A `KeychainStore` scoped to a fresh service name, that service name (for
    /// raw `SecItem*` queries), and its teardown. `cleanup` deletes the default
    /// `providerID` item; tests that create other providers add their own
    /// `defer`.
    private struct ScopedStore {
        let store: KeychainStore
        let service: String
        let cleanup: () -> Void
    }

    private func makeStore() -> ScopedStore {
        let service = "mimi.app.tests.\(UUID().uuidString)"
        let store = KeychainStore(service: service)
        return ScopedStore(store: store, service: service, cleanup: { store.deleteKey(for: providerID) })
    }

    // MARK: - Round trip

    @Test("a saved key reads back unchanged")
    func savedKeyReadsBackUnchanged() throws {
        let scoped = makeStore()
        defer { scoped.cleanup() }
        let apiKey = "sk-test-\(UUID().uuidString)"

        try scoped.store.saveKey(apiKey, for: providerID)

        #expect(scoped.store.readKey(for: providerID) == apiKey)
    }

    // MARK: - Overwrite

    @Test("saving over an existing key replaces it")
    func savingOverExistingKeyReplacesIt() throws {
        let scoped = makeStore()
        defer { scoped.cleanup() }
        let originalKey = "sk-original"
        let replacementKey = "sk-replacement"

        try scoped.store.saveKey(originalKey, for: providerID)
        try scoped.store.saveKey(replacementKey, for: providerID)

        #expect(scoped.store.readKey(for: providerID) == replacementKey)
    }

    // MARK: - Delete

    @Test("delete removes the key")
    func deleteRemovesKey() throws {
        let scoped = makeStore()
        defer { scoped.cleanup() }

        try scoped.store.saveKey("sk-gone", for: providerID)
        scoped.store.deleteKey(for: providerID)

        #expect(scoped.store.readKey(for: providerID) == nil)
    }

    // MARK: - Missing key

    @Test("reading an unconfigured provider degrades to nil")
    func missingKeyReadsAsNil() {
        let scoped = makeStore()
        defer { scoped.cleanup() }

        #expect(scoped.store.readKey(for: providerID) == nil)
    }

    // MARK: - Isolation

    @Test("keys are scoped per service and per provider account")
    func keysAreScopedPerServiceAndProvider() throws {
        let scoped = makeStore()
        defer { scoped.cleanup() }
        let otherStore = KeychainStore(service: "mimi.app.tests.\(UUID().uuidString)")
        defer { otherStore.deleteKey(for: providerID) }

        try scoped.store.saveKey("sk-a", for: providerID)
        try scoped.store.saveKey("sk-b", for: "other-provider")
        defer { scoped.store.deleteKey(for: "other-provider") }

        #expect(scoped.store.readKey(for: providerID) == "sk-a")
        #expect(scoped.store.readKey(for: "other-provider") == "sk-b")
        #expect(otherStore.readKey(for: providerID) == nil)
        #expect(scoped.store.readKey(for: "unknown-provider") == nil)
    }

    // MARK: - Stored attributes

    /// The store also sets `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
    /// but the legacy (non-data-protection) macOS keychain neither enforces nor
    /// returns that attribute, so it cannot be asserted here.
    @Test("saved items are generic passwords keyed by service and account")
    func savedItemsAreGenericPasswords() throws {
        let scoped = makeStore()
        defer { scoped.cleanup() }
        try scoped.store.saveKey("sk-attrs", for: providerID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scoped.service,
            kSecAttrAccount as String: providerID,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        #expect(status == errSecSuccess)
        let attributes = try #require(item as? [String: Any])

        #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attributes[kSecAttrService as String] as? String == scoped.service)
        #expect(attributes[kSecAttrAccount as String] as? String == providerID)
    }

    // MARK: - Decode guard

    @Test("an item holding non-UTF-8 data reads as nil")
    func nonUTF8ItemReadsAsNil() throws {
        let scoped = makeStore()
        defer { scoped.cleanup() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scoped.service,
            kSecAttrAccount as String: providerID,
            kSecValueData as String: Data([0xFF, 0xFE])
        ]
        try #require(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)

        #expect(scoped.store.readKey(for: providerID) == nil)
    }

    // MARK: - Error mapping

    /// Stubs the raw `SecItem*` statuses so the update/insert failure paths are
    /// exercisable without a locked keychain.
    private struct StubKeychainOperations: KeychainItemOperations {
        let updateStatus: OSStatus
        let addStatus: OSStatus

        func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
            updateStatus
        }

        func add(_ query: CFDictionary) -> OSStatus {
            addStatus
        }

        func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
            errSecItemNotFound
        }

        func delete(_ query: CFDictionary) -> OSStatus {
            errSecSuccess
        }
    }

    private func makeStubStore(updateStatus: OSStatus, addStatus: OSStatus = errSecSuccess) -> KeychainStore {
        let service = "unused-service"
        let operations = StubKeychainOperations(updateStatus: updateStatus, addStatus: addStatus)
        return KeychainStore(service: service, operations: operations)
    }

    @Test("a failed update surfaces its OSStatus")
    func failedUpdateSurfacesStatus() {
        let store = makeStubStore(updateStatus: errSecAuthFailed)

        let error = #expect(throws: KeychainStoreError.self) {
            try store.saveKey("sk", for: providerID)
        }

        #expect(error?.status == errSecAuthFailed)
    }

    @Test("a failed insert surfaces its OSStatus")
    func failedInsertSurfacesStatus() {
        let store = makeStubStore(updateStatus: errSecItemNotFound, addStatus: errSecMissingEntitlement)

        let error = #expect(throws: KeychainStoreError.self) {
            try store.saveKey("sk", for: providerID)
        }

        #expect(error?.status == errSecMissingEntitlement)
    }
}
