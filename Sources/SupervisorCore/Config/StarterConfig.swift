// StarterConfig.swift — write a commented config.yaml on first launch.
//
// Nothing used to create this file. It was documented in the README, named in
// error messages, and read on every launch, but a fresh install simply did not
// have one: `UserConfig.parse(nil)` returned defaults and the owner was told to
// go edit a file that was not there.
//
// That became a real failure the moment the daily cost cap gained a non-nil
// default. A user who reached the cap was told "Raise cost.daily_cap_usd in
// config.yaml to resume" and found no config.yaml to raise it in.
//
// So: seed the file once, with every default written out as a comment and
// nothing active. The seeded file parses to exactly the same UserConfig as no
// file at all, which is the property the tests pin. It is documentation the
// owner can edit in place, not configuration that changes behavior.
//
// Rules:
//   1. Never touch an existing file. Not to add keys, not to fix formatting,
//      not to "upgrade" the comments. The owner's config is theirs; a writer
//      that rewrites it is a writer that eventually eats it.
//   2. A write failure is not an error worth failing a launch over. The app
//      runs fine with no config at all; a read-only disk should not stop
//      supervision.

import Foundation

public enum StarterConfig {

    /// The seeded file's body. Every line is a comment except the trailing
    /// newline, so parsing it yields the same defaults as an absent file.
    ///
    /// The cap line quotes `UserConfig.defaultDailyCostCapUSD` rather than a
    /// literal, so the documentation cannot drift from the value in force.
    public static var template: String {
        let cap = String(format: "%.2f", UserConfig.defaultDailyCostCapUSD)
        return """
        # Supervisor configuration.
        #
        # Every setting below is commented out and shows its default. Uncomment
        # a line to change it. Supervisor re-reads this file while it runs, so
        # edits take effect without a restart.

        # cost:
        #   # Hard daily spend cap, in US dollars, across every model call
        #   # Supervisor makes. Resets at local midnight. This is a runaway
        #   # backstop, not a budget: a normal day costs well under $1, and
        #   # heavy use of the Anthropic provider is around $2.67/day.
        #   #
        #   # Set it to 0 to turn the cap off entirely and accept an unbounded
        #   # bill. There is no way to have a cap that never refuses a call.
        #   daily_cap_usd: \(cap)

        # remote_notify:
        #   # Send escalations off this Mac (phone, Discord, Slack, ntfy).
        #   # Both this switch AND a webhook URL in the Keychain are required
        #   # before anything leaves the machine. The URL is a credential and
        #   # is never stored in this file.
        #   enabled: false
        #   # minimal sends Supervisor's own verdict plus the project folder
        #   # name; full also quotes the command or question that triggered it.
        #   detail: minimal
        #   # auto reads the format from the webhook host. Set it explicitly
        #   # (ntfy) for a self-hosted endpoint whose host says nothing.
        #   format: auto

        # hover:
        #   # Extra terminal bundle IDs to treat as Claude Code hosts, on top
        #   # of the built-in list.
        #   known_terminals:
        #     - com.example.YourTerminal

        # # Also supervise OpenAI Codex sessions. Absent means auto: on when
        # # ~/.codex exists. Codex sessions run the identical safety rubric.
        # supervise_codex: true

        """
    }

    /// Write the starter file at `path` if and only if nothing is there.
    ///
    /// - Returns: true when a file was created by this call.
    @discardableResult
    public static func seedIfAbsent(at path: URL, trace: TraceLog = .shared) -> Bool {
        guard !FileManager.default.fileExists(atPath: path.path) else { return false }
        do {
            // Atomic, same as every other write into this directory: a partial
            // config.yaml would parse as a config, not as an absence.
            try template.write(to: path, atomically: true, encoding: .utf8)
            trace.emit("config", "starter config.yaml written (all defaults, all commented)")
            return true
        } catch {
            // The error text can name the path, which carries the account name.
            trace.emit("config", "starter config.yaml not written; continuing on built-in defaults")
            return false
        }
    }

    /// The config path as the owner should be told it, with the home directory
    /// written `~`.
    ///
    /// Deliberately NOT the absolute path. This string goes into escalation
    /// copy that is delivered to Discord, Slack and phones, and an absolute
    /// path under `/Users/<name>` publishes the account name off the machine
    /// for a message whose only job is to say which file to edit. A path that
    /// somehow resolves outside the home directory degrades to the bare
    /// filename rather than leaking the whole tree.
    public static func displayPath(for configPath: URL, home: URL = ConfigPaths.resolvedHome) -> String {
        let full = configPath.path
        let homePath = home.path
        if full.hasPrefix(homePath + "/") {
            return "~" + full.dropFirst(homePath.count)
        }
        return configPath.lastPathComponent
    }

    /// Where the running process's config.yaml actually is, in the form
    /// owner-facing copy should use. Resolves through `ConfigPaths`, so an
    /// instance running under `SUPERVISOR_HOME` names its own file rather than
    /// the live install's.
    public static var ownerFacingLocation: String {
        displayPath(for: ConfigPaths().configPath)
    }
}
