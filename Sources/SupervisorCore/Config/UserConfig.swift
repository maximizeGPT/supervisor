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
//
// Remote escalation delivery (2026-08-09) adds a `remote_notify` block
// holding the switch and the verbosity for off-machine delivery:
//
//   remote_notify:
//     enabled: true       # default false. The webhook URL lives in the
//                         # Keychain, never here.
//     detail: minimal     # minimal (default) | full
//
// Both halves have to be true for anything to leave the Mac: this switch,
// and a webhook URL in the Keychain. Missing either one and the app wires
// the plain banner notifier exactly as it did before.

import Foundation

public struct UserConfig: Sendable, Equatable {

    /// Bundle IDs the user added via config.yaml, merged with the
    /// hardcoded defaults in HoverWindowController.claudeCodeHostApps.
    public let additionalHostApps: [String]

    /// v0.3.0: hard daily spend cap in USD as WRITTEN in the file
    /// (`cost.daily_cap_usd`). nil = the key is absent or unparseable.
    /// Read `effectiveDailyCostCapUSD`, not this, to gate a call: an owner who
    /// never opens config.yaml still gets a cap.
    public let dailyCostCapUSD: Double?

    /// The cap an install has when config.yaml says nothing about spend
    /// (2026-09-05). It used to be "no cap at all," which is the wrong default
    /// for a background process that talks to a metered API on a timer: the
    /// owner filled $10 of DeepSeek credit overnight and had nothing standing
    /// between him and the bill.
    ///
    /// This has to be a RUNAWAY BACKSTOP, not a throttle on normal use, and
    /// the first pass at $2.00/day was a throttle. Onboarding tells an
    /// Anthropic user to expect about $80/month at heavy use, which is
    /// $2.67/day: the documented normal user hit the default cap mid-day,
    /// supervision stopped, and the remedy the cap-hit message named was a
    /// config.yaml that a fresh install does not have.
    ///
    /// The three numbers that set this one:
    ///   - a normal day, with the idle-cost fix in this release, is well
    ///     under $1
    ///   - heavy Anthropic use is ~$2.67/day ($80/month, the onboarding copy)
    ///   - the runaway this release fixed burned ~$11/day
    ///
    /// $5.00 clears the documented heavy day by nearly 2x, so nobody using
    /// the product as described ever meets it, and still catches the runaway
    /// before it has cost $6. A cap that fires on correct use trains the
    /// owner to raise it or switch it off, which leaves them with no backstop
    /// at all.
    public static let defaultDailyCostCapUSD: Double = 5.00

    /// Whether the owner explicitly turned the cap OFF by writing
    /// `daily_cap_usd: 0` (or a negative value). Distinct from "the key is
    /// absent," which now means the default cap, so opting out stays possible.
    /// A garbage value (`daily_cap_usd: lots`) is a typo, not an opt-out, and
    /// leaves the default in place.
    public let dailyCostCapDisabled: Bool

    /// The cap to actually gate on: the owner's value, their explicit opt-out
    /// (nil), or the default.
    public var effectiveDailyCostCapUSD: Double? {
        if let dailyCostCapUSD { return dailyCostCapUSD }
        return dailyCostCapDisabled ? nil : UserConfig.defaultDailyCostCapUSD
    }

    /// Whether to also supervise OpenAI Codex sessions (`supervise_codex:`).
    /// nil = auto (on when ~/.codex exists); false explicitly opts out. Codex
    /// sessions flow through the identical triage + safety rubric as Claude Code.
    public let superviseCodex: Bool?

    /// `remote_notify.enabled`. Off unless the file says otherwise, so an
    /// install that never touches config.yaml never posts anywhere.
    public let remoteNotifyEnabled: Bool

    /// `remote_notify.detail`. Defaults to `.minimal`, which sends
    /// Supervisor's verdict and quotes nothing from the session. An
    /// unrecognized value falls back to `.minimal` rather than failing the
    /// parse, because a typo must not silently widen what gets sent.
    public let remoteNotifyDetail: RemoteNotifyDetail

    /// `remote_notify.format` (C13). nil = auto-detect from the webhook's
    /// host, which covers Discord, Slack and ntfy.sh; an explicit value
    /// (usually `ntfy`) is for endpoints whose host says nothing, like a
    /// self-hosted ntfy server. `auto`, absence, and typos all mean nil.
    public let remoteNotifyFormat: RemoteNotifyFormat?

    public init(
        additionalHostApps: [String] = [],
        dailyCostCapUSD: Double? = nil,
        dailyCostCapDisabled: Bool = false,
        superviseCodex: Bool? = nil,
        remoteNotifyEnabled: Bool = false,
        remoteNotifyDetail: RemoteNotifyDetail = .minimal,
        remoteNotifyFormat: RemoteNotifyFormat? = nil
    ) {
        self.additionalHostApps = additionalHostApps
        self.dailyCostCapUSD = dailyCostCapUSD
        self.dailyCostCapDisabled = dailyCostCapDisabled
        self.superviseCodex = superviseCodex
        self.remoteNotifyEnabled = remoteNotifyEnabled
        self.remoteNotifyDetail = remoteNotifyDetail
        self.remoteNotifyFormat = remoteNotifyFormat
    }

    /// Parse a config.yaml string. Returns a default (empty) config
    /// if the string is nil, empty, or malformed. Never throws —
    /// config parse failures degrade to defaults silently (the user
    /// still gets the hardcoded terminal list).
    public static func parse(_ yaml: String?) -> UserConfig {
        guard let yaml, !yaml.isEmpty else { return UserConfig() }

        var inKnownTerminals = false
        var inRemoteNotify = false
        /// Indentation of the `remote_notify:` header line. Lines indented
        /// DEEPER than this belong to the block; the first line back at (or
        /// above) this level ends it. Tracked so an unrecognized key inside
        /// the block (a typo, or a key from a newer version) skips instead
        /// of silently closing the block and dropping everything after it.
        var remoteNotifyIndent = 0
        var bundleIDs: [String] = []
        var dailyCostCapUSD: Double?
        var dailyCostCapDisabled = false
        var superviseCodex: Bool?
        var remoteEnabled = false
        var remoteDetail: RemoteNotifyDetail = .minimal
        var remoteFormat: RemoteNotifyFormat?

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Detect the `known_terminals:` key.
            if trimmed == "known_terminals:" {
                inKnownTerminals = true
                inRemoteNotify = false
                continue
            }

            // `remote_notify:` opens a block of scalar keys. Matched on the
            // comment-stripped line so a trailing `# ...` on the header does
            // not hide the whole block. Both section detectors clear the
            // other so a file listing them in either order parses the same.
            let headerCandidate = trimmed.components(separatedBy: " #").first?
                .trimmingCharacters(in: .whitespaces) ?? trimmed
            if headerCandidate == "remote_notify:" {
                inRemoteNotify = true
                remoteNotifyIndent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                inKnownTerminals = false
                continue
            }

            // Detect the `daily_cap_usd:` key (nominally under `cost:`,
            // but — like known_terminals — the parser is forgiving about
            // nesting depth). Three outcomes, and the difference between the
            // last two is the point (2026-09-05): a positive value is the cap;
            // an explicit zero or negative is the owner turning the cap OFF; a
            // garbage or missing value is a typo or an untouched file, and
            // leaves `UserConfig.defaultDailyCostCapUSD` in force. A typo must
            // never be the thing that removes the spend ceiling.
            if trimmed.hasPrefix("daily_cap_usd:") {
                inKnownTerminals = false
                inRemoteNotify = false
                let value = trimmed.dropFirst("daily_cap_usd:".count)
                    .trimmingCharacters(in: .whitespaces)
                    // Strip inline comments.
                    .components(separatedBy: " #").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if let cap = Double(value), cap.isFinite {
                    if cap > 0 {
                        dailyCostCapUSD = cap
                        dailyCostCapDisabled = false
                    } else {
                        dailyCostCapUSD = nil
                        dailyCostCapDisabled = true
                    }
                }
                continue
            }

            // Detect the `supervise_codex:` boolean toggle (forgiving about
            // nesting, like the other keys). Unrecognized values leave it nil
            // (auto), which is on when Codex is installed.
            if trimmed.hasPrefix("supervise_codex:") {
                inKnownTerminals = false
                inRemoteNotify = false
                let value = trimmed.dropFirst("supervise_codex:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: " #").first?
                    .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                if value == "true" || value == "yes" { superviseCodex = true }
                else if value == "false" || value == "no" { superviseCodex = false }
                continue
            }

            // Scalar keys inside `remote_notify:`. Membership is by
            // indentation, YAML's own rule: any line indented deeper than
            // the header is in the block (an unrecognized key neither
            // parses nor closes it), and the first line back at the
            // header's level ends it. That first-line-back rule is a
            // safety property, not a convenience: a stray top-level
            // `enabled: true` lands outside the block and can never switch
            // on a network channel the owner never asked for.
            if inRemoteNotify {
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                if indent > remoteNotifyIndent {
                    if let value = Self.scalarValue(of: "enabled", in: trimmed) {
                        remoteEnabled = (value == "true" || value == "yes" || value == "on")
                    } else if let value = Self.scalarValue(of: "detail", in: trimmed) {
                        remoteDetail = RemoteNotifyDetail(rawValue: value) ?? .minimal
                    } else if let value = Self.scalarValue(of: "format", in: trimmed) {
                        // "auto" and anything unrecognized mean detect-from-
                        // host; only a real format name pins the wire shape.
                        remoteFormat = RemoteNotifyFormat(rawValue: value)
                    }
                    continue
                }
                inRemoteNotify = false
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

        return UserConfig(
            additionalHostApps: bundleIDs,
            dailyCostCapUSD: dailyCostCapUSD,
            dailyCostCapDisabled: dailyCostCapDisabled,
            superviseCodex: superviseCodex,
            remoteNotifyEnabled: remoteEnabled,
            remoteNotifyDetail: remoteDetail,
            remoteNotifyFormat: remoteFormat
        )
    }

    /// Pull the value out of a `key: value` line, or nil if this line is not
    /// that key. Strips inline comments and surrounding quotes, and
    /// lowercases the result, since every value this parser accepts is a
    /// case-insensitive keyword.
    private static func scalarValue(of key: String, in trimmed: String) -> String? {
        let prefix = key + ":"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let raw = trimmed.dropFirst(prefix.count)
            .components(separatedBy: " #").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return raw
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
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
