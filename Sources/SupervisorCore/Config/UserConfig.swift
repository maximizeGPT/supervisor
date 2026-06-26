// UserConfig.swift
//
// Reads `~/Library/Application Support/Supervisor/config.yaml` and
// exposes user-configurable knobs. The YAML subset is deliberately
// minimal — one top-level key `hover` with one sub-key
// `known_terminals` (list of bundle IDs). Parsed with string
// operations, no Yams dependency; if the config format grows complex,
// Yams lands then per §1a (restraint).
//
// v0.1.x Issue #3: user-configurable terminals list.

import Foundation

public struct UserConfig: Sendable, Equatable {

    /// Bundle IDs the user added via config.yaml, merged with the
    /// hardcoded defaults in HoverWindowController.claudeCodeHostApps.
    public let additionalHostApps: [String]

    public init(additionalHostApps: [String] = []) {
        self.additionalHostApps = additionalHostApps
    }

    /// Parse a config.yaml string. Returns a default (empty) config
    /// if the string is nil, empty, or malformed. Never throws —
    /// config parse failures degrade to defaults silently (the user
    /// still gets the hardcoded terminal list).
    public static func parse(_ yaml: String?) -> UserConfig {
        guard let yaml, !yaml.isEmpty else { return UserConfig() }

        var inKnownTerminals = false
        var bundleIDs: [String] = []

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Detect the `known_terminals:` key.
            if trimmed == "known_terminals:" {
                inKnownTerminals = true
                continue
            }

            // If we're in the known_terminals list, collect `- value` entries.
            if inKnownTerminals {
                if trimmed.hasPrefix("- ") {
                    let value = trimmed.dropFirst(2)
                        .trimmingCharacters(in: .whitespaces)
                        // Strip inline comments.
                        .components(separatedBy: " #").first?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    if !value.isEmpty {
                        bundleIDs.append(value)
                    }
                } else if !trimmed.hasPrefix("-") {
                    // Non-list-item line — we've left the list.
                    inKnownTerminals = false
                }
            }
        }

        return UserConfig(additionalHostApps: bundleIDs)
    }

    /// Load from disk. Returns default config if the file doesn't exist
    /// or can't be read.
    public static func load(from path: URL) -> UserConfig {
        guard let contents = try? String(contentsOf: path, encoding: .utf8) else {
            return UserConfig()
        }
        return parse(contents)
    }
}
