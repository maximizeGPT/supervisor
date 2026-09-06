// RemoteNotifyURLStore.swift. Keychain slot for the remote-escalation
// webhook URL.
//
// Follows the `KeychainAPIKeyStore` / `LLMProvider.keychainServiceFor`
// pattern exactly: the service name is computed off
// `LLMProvider.keychainServiceBase`, so `$SUPERVISOR_KEYCHAIN_PREFIX` (the
// E2E isolation seam) namespaces this item the same way it namespaces the
// provider keys, and an isolated harness instance can never write over the
// owner's real webhook. Accessibility is `.afterFirstUnlock` and the item is
// labelled so the user can find and delete it in Keychain Access.
//
// A Discord or Slack incoming-webhook URL is a bearer credential. Anyone
// holding the string can post as the owner, forever, with no other secret.
// It belongs in the Keychain next to the API keys and it does not belong in
// `config.yaml`, which is a plaintext file people paste into issues. That
// split is deliberate: the SWITCH is in config.yaml where it is visible and
// diffable, the SECRET is in the Keychain where it is not.

import Foundation
@preconcurrency import KeychainAccess

/// Storage for the remote-notify webhook URL. Protocol so tests and the
/// onboarding flow can substitute an in-memory store.
public protocol RemoteNotifyURLStore: Sendable {
    /// Stored webhook URL, or nil if the owner never set one.
    func read() throws -> String?
    /// Save a webhook URL. Overwrites any existing value.
    func write(_ url: String) throws
    /// Remove the stored URL. No-op if not set. This is the off switch of
    /// last resort: with no URL, `RemoteNotifier` is never constructed.
    func delete() throws
}

public struct KeychainRemoteNotifyURLStore: RemoteNotifyURLStore, @unchecked Sendable {
    // KeychainAccess's `Keychain` type isn't Sendable-annotated; same
    // @unchecked rationale as KeychainAPIKeyStore.

    /// Keychain service. Production resolves to
    /// `live.supervisor.api.remotenotify`, grouping the webhook with the
    /// provider keys and inheriting their E2E prefix isolation.
    public static var service: String {
        service(environment: ProcessInfo.processInfo.environment)
    }

    /// Injectable-environment variant, same rationale as
    /// `LLMProvider.keychainServiceBase(environment:)`: ProcessInfo caches
    /// its environment snapshot on first access, so a test asserting the
    /// prefix override cannot rely on an in-test `setenv`.
    public static func service(environment: [String: String]) -> String {
        LLMProvider.keychainServiceBase(environment: environment) + ".remotenotify"
    }
    public static let accountName = "webhook-url"

    public init() {}

    public func read() throws -> String? {
        try keychain().getString(Self.accountName)
    }

    public func write(_ url: String) throws {
        try keychain().set(url, key: Self.accountName)
    }

    public func delete() throws {
        try keychain().remove(Self.accountName)
    }

    private func keychain() -> Keychain {
        Keychain(service: Self.service)
            .accessibility(.afterFirstUnlock)
            .label("Supervisor Remote Notify Webhook")
    }
}

/// In-memory store for tests. Not thread-safe; tests are single-threaded.
public final class InMemoryRemoteNotifyURLStore: RemoteNotifyURLStore, @unchecked Sendable {
    private var value: String?
    public init(value: String? = nil) { self.value = value }
    public func read() throws -> String? { value }
    public func write(_ url: String) throws { value = url }
    public func delete() throws { value = nil }
}
