// SecAccessKeychainItemOps.swift — the real Keychain primitives behind
// TrustedAppKeychainWriter.
//
// KeychainAccess (used everywhere else in the app) cannot express an ACL, so
// items it creates trust only the process that created them. For an in-app
// write that is exactly right. For a write from SupervisorDevTools it is the
// bug: the app is a different binary, so the app's next read prompts.
//
// Setting a trusted-application list needs SecAccessCreate + kSecAttrAccess,
// which live on the file-based ("legacy") Keychain API. Those symbols are
// marked deprecated, and there is no replacement that can express an ACL —
// the data-protection Keychain has no equivalent concept. Every function that
// touches them is therefore itself marked deprecated, which is also what stops
// the deprecation warnings from spilling into the build.
//
// Deliberately NOT setting kSecUseDataProtectionKeychain: the app's
// KeychainAccess reads go to the same file-based login keychain, and an item
// written to the other one would simply be invisible to it.

import Foundation
import Security

public struct SecAccessKeychainItemOps: KeychainItemOps {

    public struct OSStatusError: Error, CustomStringConvertible {
        public let operation: String
        public let status: OSStatus
        public var description: String {
            // SecCopyErrorMessageString can quote the item, so only the
            // numeric status is ever surfaced. Keychain errors are one of the
            // documented ways a secret leaks into a log.
            "\(operation) failed (OSStatus \(status))"
        }
    }

    public init() {}

    public func read(service: String, account: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw OSStatusError(operation: "SecItemCopyMatching", status: status)
        }
        guard let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deleteIfPresent(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw OSStatusError(operation: "SecItemDelete", status: status)
    }

    @available(macOS, deprecated: 10.10, message: "SecAccess is the only API that can set a Keychain ACL")
    public func add(
        service: String,
        account: String,
        value: String,
        label: String,
        trustedAppPaths: [String]
    ) throws {
        var trusted: [SecTrustedApplication] = []
        // The writing process itself goes in first, so re-running the CLI to
        // rotate the key does not prompt on its own backup read. A nil path
        // means "the application calling this function".
        var selfApp: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &selfApp) == errSecSuccess, let selfApp {
            trusted.append(selfApp)
        }
        for path in trustedAppPaths {
            var app: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &app)
            guard status == errSecSuccess, let app else {
                throw OSStatusError(operation: "SecTrustedApplicationCreateFromPath(\(path))", status: status)
            }
            trusted.append(app)
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(label as CFString, trusted as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw OSStatusError(operation: "SecAccessCreate", status: accessStatus)
        }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: label,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccess as String: access,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OSStatusError(operation: "SecItemAdd", status: status)
        }
    }
}

/// In-memory ops for tests. Records every call so the ordering contract can be
/// asserted, and can be told to fail a specific operation.
public final class RecordingKeychainItemOps: KeychainItemOps, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public let kind: String
        public let service: String
        public let account: String
        public let trustedAppPaths: [String]
    }

    public private(set) var calls: [Call] = []
    public private(set) var items: [String: String] = [:]

    /// Accounts whose `add` must throw, and whether `read` must throw.
    public var failAddForAccounts: Set<String> = []
    public var failDeleteForAccounts: Set<String> = []
    public var readThrows = false

    public struct Boom: Error, CustomStringConvertible {
        public let what: String
        public var description: String { what }
    }

    public init(initial: [String: String] = [:]) {
        self.items = initial
    }

    private func key(_ service: String, _ account: String) -> String { service + "|" + account }

    public func read(service: String, account: String) throws -> String? {
        calls.append(Call(kind: "read", service: service, account: account, trustedAppPaths: []))
        if readThrows { throw Boom(what: "read denied") }
        return items[key(service, account)]
    }

    public func deleteIfPresent(service: String, account: String) throws {
        calls.append(Call(kind: "delete", service: service, account: account, trustedAppPaths: []))
        if failDeleteForAccounts.contains(account) { throw Boom(what: "delete denied") }
        items.removeValue(forKey: key(service, account))
    }

    public func add(
        service: String,
        account: String,
        value: String,
        label: String,
        trustedAppPaths: [String]
    ) throws {
        calls.append(Call(kind: "add", service: service, account: account, trustedAppPaths: trustedAppPaths))
        if failAddForAccounts.contains(account) { throw Boom(what: "add denied") }
        items[key(service, account)] = value
    }

    /// Value stored at `service`/`account`, bypassing the failure switches.
    public func stored(service: String, account: String) -> String? {
        items[key(service, account)]
    }
}
