// ConfigPaths.swift
//
// Single source of truth for "where does X live" answers. Tests stub
// `home` to redirect the whole tree under a temp directory; production
// code uses the real home.

import Foundation

public struct ConfigPaths: Sendable {

    /// Root of the user's home directory. Production: `~`. Tests: a temp dir.
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// `~/Library/Application Support/Supervisor/` — config + DB + heartbeat.
    public var appSupportDir: URL {
        home.appendingPathComponent("Library/Application Support/Supervisor", isDirectory: true)
    }

    /// `~/Library/Logs/Supervisor/` — trace log.
    public var logsDir: URL {
        home.appendingPathComponent("Library/Logs/Supervisor", isDirectory: true)
    }

    /// `~/Library/Application Support/Supervisor/supervisor.sqlite`
    public var databasePath: URL {
        appSupportDir.appendingPathComponent("supervisor.sqlite", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/heartbeat.txt`
    public var heartbeatPath: URL {
        appSupportDir.appendingPathComponent("heartbeat.txt", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/recovery/` — one markdown file
    /// per pause/kill intervention, written by the router immediately before
    /// it signals the Claude Code process. Read by the user (or the resumed /
    /// next-launched assistant) to recover context after the intervention.
    /// v0.1.6.
    public var recoveryDir: URL {
        appSupportDir.appendingPathComponent("recovery", isDirectory: true)
    }

    /// `~/Library/Application Support/Supervisor/rubric.yaml` (v0.1.4+).
    public var rubricPath: URL {
        appSupportDir.appendingPathComponent("rubric.yaml", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/config.yaml`
    public var configPath: URL {
        appSupportDir.appendingPathComponent("config.yaml", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/confirmations.yaml` (v0.1.6+).
    public var confirmationsPath: URL {
        appSupportDir.appendingPathComponent("confirmations.yaml", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/active-provider.json` (v0.2.0+).
    /// Tiny one-key JSON tracking which LLM provider triage should call.
    /// Backed by `FileActiveProviderStore`.
    public var activeProviderPath: URL {
        appSupportDir.appendingPathComponent("active-provider.json", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/self-rebuild.marker`
    /// Written by the deploy step right before relaunching a freshly
    /// built Supervisor over the running one. The app reads it once at
    /// launch, announces "Supervisor updated itself" on the hover, and
    /// deletes it. Contents are an optional version string.
    public var selfRebuildMarkerPath: URL {
        appSupportDir.appendingPathComponent("self-rebuild.marker", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/ax-skipped.marker`
    /// v0.3.0 (F5): written when the user chose "Skip for now" on the
    /// Accessibility step of onboarding. Its presence means "the user
    /// deliberately declined AX" — a notify-only setup. The launch gate
    /// treats that as fully onboarded and does NOT re-run the wizard on
    /// every launch. Harmless once AX is actually granted: the gate checks
    /// the live AX grant first and only consults this marker when AX is off.
    public var axSkippedMarkerPath: URL {
        appSupportDir.appendingPathComponent("ax-skipped.marker", isDirectory: false)
    }

    /// `~/Library/Logs/Supervisor/supervisor.log`
    public var traceLogPath: URL {
        logsDir.appendingPathComponent("supervisor.log", isDirectory: false)
    }

    /// `~/.claude/projects/` — root of Claude Code's per-project session
    /// directories. Read-only from Supervisor's perspective.
    public var claudeProjectsDir: URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Ensure every directory we own exists. Safe to call on every launch;
    /// no-ops if dirs are already there.
    public func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
    }
}
