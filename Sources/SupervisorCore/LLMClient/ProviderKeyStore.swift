// ProviderKeyStore.swift — v0.2.0 per-provider Keychain storage.
//
// v0.1.x used a single Keychain item ("live.supervisor.api") tied to
// the Anthropic key. v0.2.0 keys each provider's secret under its own
// Keychain service so users can have several active at once and switch
// without re-entering. Also adds `ActiveProviderStore` — a tiny JSON
// file that records which provider's key triage should use.
//
// Migration: on first launch of v0.2.0, `migrateLegacyKeyIfPresent`
// moves the old Anthropic-only key into its provider-namespaced slot
// and sets `activeProvider = .anthropic`, so existing installs keep
// working without re-onboarding.

import Foundation
@preconcurrency import KeychainAccess

/// Per-provider API key storage. Lets the rest of the system ask
/// "what's the key for X provider?" without caring whether it lives
/// in the macOS Keychain or an in-memory test stub.
public protocol ProviderKeyStore: Sendable {
    /// Stored key for `provider`, or nil if not set.
    func read(_ provider: LLMProvider) throws -> String?
    /// Save a key for `provider`. Overwrites any existing value.
    func write(_ key: String, for provider: LLMProvider) throws
    /// Remove the stored key for `provider`. No-op if not set.
    func delete(_ provider: LLMProvider) throws
}

public struct KeychainProviderKeyStore: ProviderKeyStore, @unchecked Sendable {
    public static let accountName = "api-key"

    public init() {}

    public func read(_ provider: LLMProvider) throws -> String? {
        try keychain(for: provider).getString(Self.accountName)
    }

    public func write(_ key: String, for provider: LLMProvider) throws {
        try keychain(for: provider).set(key, key: Self.accountName)
    }

    public func delete(_ provider: LLMProvider) throws {
        try keychain(for: provider).remove(Self.accountName)
    }

    private func keychain(for provider: LLMProvider) -> Keychain {
        Keychain(service: provider.keychainService)
            .accessibility(.afterFirstUnlock)
            .label("Supervisor — \(provider.displayName) API Key")
    }
}

/// In-memory store for tests. Not thread-safe; tests are single-threaded.
public final class InMemoryProviderKeyStore: ProviderKeyStore, @unchecked Sendable {
    private var values: [LLMProvider: String] = [:]
    public init() {}
    public func read(_ provider: LLMProvider) throws -> String? {
        values[provider]
    }
    public func write(_ key: String, for provider: LLMProvider) throws {
        values[provider] = key
    }
    public func delete(_ provider: LLMProvider) throws {
        values.removeValue(forKey: provider)
    }
}

// MARK: - Active provider selection

/// Tracks which provider the triage engine should call. Backed by a
/// JSON file under Application Support (cheap, atomic-write, easy to
/// inspect / reset by hand).
public protocol ActiveProviderStore: Sendable {
    func read() throws -> LLMProvider?
    func write(_ provider: LLMProvider) throws
    func delete() throws
}

public struct FileActiveProviderStore: ActiveProviderStore, Sendable {
    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public func read() throws -> LLMProvider? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        let raw = try JSONDecoder().decode(StoredActive.self, from: data)
        return raw.activeProvider
    }

    public func write(_ provider: LLMProvider) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(StoredActive(activeProvider: provider))
        try data.write(to: path, options: [.atomic])
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private struct StoredActive: Codable {
        let activeProvider: LLMProvider
    }
}

public final class InMemoryActiveProviderStore: ActiveProviderStore, @unchecked Sendable {
    private var value: LLMProvider?
    public init() {}
    public func read() throws -> LLMProvider? { value }
    public func write(_ provider: LLMProvider) throws { value = provider }
    public func delete() throws { value = nil }
}

// MARK: - Migration

/// One-shot migration from the v0.1.x single-key Keychain to the v0.2.0
/// per-provider layout. Idempotent: safe to call on every launch. Does
/// nothing if either (a) the legacy item is absent, or (b) the
/// Anthropic-namespaced item already exists (meaning we already
/// migrated, or the user has a fresh v0.2.0 install).
///
/// On a successful migration this function:
///   1. Copies the legacy key value into the Anthropic-namespaced slot.
///   2. Sets the active provider to `.anthropic` (so triage keeps
///      calling the same model the user was on yesterday).
///   3. Deletes the legacy item so future launches don't re-migrate.
///
/// Returns `true` iff a migration actually happened (useful for the
/// trace log line).
@discardableResult
public func migrateLegacyKeyIfPresent(
    keys: ProviderKeyStore,
    active: ActiveProviderStore,
    trace: TraceLog = .shared
) -> Bool {
    let legacyService = LLMProvider.legacyAnthropicKeychainService
    let legacy = Keychain(service: legacyService)

    // If we already have an Anthropic-namespaced key, no migration needed.
    // (`try?` flattens the nested optional, so a non-nil result already means
    // "read succeeded AND a key is stored" — no second nil check needed.)
    if (try? keys.read(.anthropic)) != nil {
        return false
    }
    // Read the legacy item.
    guard let legacyKey = try? legacy.getString("anthropic-api-key"),
          !legacyKey.isEmpty
    else {
        return false
    }
    // Copy → delete → record active.
    do {
        try keys.write(legacyKey, for: .anthropic)
        try active.write(.anthropic)
        try legacy.remove("anthropic-api-key")
        trace.emit("provider", "migrated legacy Anthropic key → per-provider slot")
        return true
    } catch {
        trace.emit("provider", "ERROR legacy-key migration failed: \(error)")
        return false
    }
}
