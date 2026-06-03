// Keychain.swift
//
// Thin wrapper around KeychainAccess for the Anthropic API key.
//
// The Keychain is the right home for this. macOS unlocks it automatically
// on user login; no extra prompts beyond what the user is already used
// to. The service name doubles as the bundle id so production and tests
// can coexist on the same machine via different service names.

import Foundation
@preconcurrency import KeychainAccess

public protocol APIKeyStore: Sendable {
    /// Stored key, or nil if not set.
    func read() throws -> String?
    /// Save a key. Overwrites any existing value.
    func write(_ key: String) throws
    /// Remove the stored key. No-op if not set.
    func delete() throws
}

public struct KeychainAPIKeyStore: APIKeyStore, @unchecked Sendable {
    // KeychainAccess's `Keychain` type isn't Sendable-annotated; all of its
    // operations are thread-safe under the hood (backed by Apple's Security
    // framework, which is documented as such). @unchecked is the pragmatic
    // path until KeychainAccess gains real Sendable conformance.

    public static let defaultService = "live.supervisor.api"
    public static let accountName = "anthropic-api-key"

    private let keychain: Keychain

    public init(service: String = KeychainAPIKeyStore.defaultService) {
        self.keychain = Keychain(service: service)
            .accessibility(.afterFirstUnlock)
            .label("Supervisor Anthropic API Key")
    }

    public func read() throws -> String? {
        try keychain.getString(Self.accountName)
    }

    public func write(_ key: String) throws {
        try keychain.set(key, key: Self.accountName)
    }

    public func delete() throws {
        try keychain.remove(Self.accountName)
    }
}

/// In-memory store for tests. Not thread-safe; tests are single-threaded.
public final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {

    private var value: String?
    public init() {}
    public func read() throws -> String? { value }
    public func write(_ key: String) throws { value = key }
    public func delete() throws { value = nil }
}
