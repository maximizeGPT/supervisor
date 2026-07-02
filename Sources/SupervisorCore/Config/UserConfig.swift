// UserConfig.swift
//
// Reads `~/Library/Application Support/Supervisor/config.yaml` and
// exposes user-configurable knobs. The YAML subset is deliberately
// minimal — `hover.known_terminals` (list of bundle IDs) and, as of
// v0.3.0, `cost.daily_cap_usd` (hard daily spend cap). Parsed with
// string operations, no Yams dependency; if the config format grows
// complex, Yams lands then per §1a (restraint).
//
// v0.1.x Issue #3: user-configurable terminals list.

import Foundation

public struct UserConfig: Sendable, Equatable {

    /// Bundle IDs the user added via config.yaml, merged with the
    /// hardcoded defaults in HoverWindowController.claudeCodeHostApps.
    public let additionalHostApps: [String]

    /// v0.3.0: hard daily spend cap in USD (`cost.daily_cap_usd`).
    /// nil = no cap configured (the default). Once today's recorded
    /// spend reaches this value, LLM calls are refused before any
    /// network request is made.
    public let dailyCostCapUSD: Double?

    public init(additionalHostApps: [String] = [], dailyCostCapUSD: Double? = nil) {
        self.additionalHostApps = additionalHostApps
        self.dailyCostCapUSD = dailyCostCapUSD
    }

    /// Parse a config.yaml string. Returns a default (empty) config
    /// if the string is nil, empty, or malformed. Never throws —
    /// config parse failures degrade to defaults silently (the user
    /// still gets the hardcoded terminal list).
    public static func parse(_ yaml: String?) -> UserConfig {
        guard let yaml, !yaml.isEmpty else { return UserConfig() }

        var inKnownTerminals = false
        var bundleIDs: [String] = []
        var dailyCostCapUSD: Double?

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

            // Detect the `daily_cap_usd:` key (nominally under `cost:`,
            // but — like known_terminals — the parser is forgiving about
            // nesting depth). Garbage or non-positive values degrade to
            // nil (no cap) silently, matching the file's contract.
            if trimmed.hasPrefix("daily_cap_usd:") {
                inKnownTerminals = false
                let value = trimmed.dropFirst("daily_cap_usd:".count)
                    .trimmingCharacters(in: .whitespaces)
                    // Strip inline comments.
                    .components(separatedBy: " #").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if let cap = Double(value), cap > 0, cap.isFinite {
                    dailyCostCapUSD = cap
                }
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

        return UserConfig(additionalHostApps: bundleIDs, dailyCostCapUSD: dailyCostCapUSD)
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
