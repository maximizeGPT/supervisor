// ConfigPaths.swift
//
// Single source of truth for "where does X live" answers. Tests stub
// `home` to redirect the whole tree under a temp directory; production
// code uses the real home.

import CryptoKit
import Foundation

public struct ConfigPaths: Sendable {

    /// Root of the user's home directory. Production: `~`. Tests: a temp dir.
    public let home: URL

    public init(home: URL = ConfigPaths.resolvedHome) {
        self.home = home
    }

    /// The home directory every Supervisor path derivation should hang off:
    /// `$SUPERVISOR_HOME` (as a file URL) when set, else the real home.
    ///
    /// This env seam exists because stubbing `$HOME` does NOT work on macOS —
    /// Foundation's `homeDirectoryForCurrentUser` resolves the passwd entry,
    /// so a test instance launched with a fake `$HOME` still reads and writes
    /// the LIVE user's Application Support, Logs, pause markers, and pidfile.
    /// `SUPERVISOR_HOME` is our own variable, honored at every raw home
    /// derivation (this type, RuntimeToggles, SafeRoots, the app's report /
    /// Codex dirs, the desktop targeter's fallbacks), which is what lets the
    /// E2E harness run a "true new user" instance fully disjoint from a live
    /// Supervisor on the same machine.
    public static var resolvedHome: URL {
        resolvedHome(environment: ProcessInfo.processInfo.environment)
    }

    /// Injectable-environment variant so tests can assert the override logic
    /// without `setenv` (ProcessInfo caches its environment snapshot on first
    /// access, so an in-test `setenv` is not reliably visible).
    public static func resolvedHome(environment: [String: String]) -> URL {
        if let override = environment["SUPERVISOR_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Short stable identity for THIS instance's home — the first 12 hex
    /// chars of sha256(resolvedHome.path). Anything cross-process but
    /// machine-GLOBAL (the duplicate-launch activate DistributedNotification,
    /// the SUPERVISOR_HOME UserDefaults suite) is namespaced by this, so two
    /// instances with different homes (the live app + an E2E test instance)
    /// can never signal or share state with each other, while poster and
    /// observer WITHIN one instance's world always agree. 12 hex = 48 bits:
    /// collision-proof for the handful of homes one machine ever sees, short
    /// enough to read inside a notification name.
    public static var homeIdentityHash: String {
        identityHash(forHomePath: resolvedHome.path)
    }

    /// Pure variant for tests and callers that already resolved a home.
    public static func identityHash(forHomePath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
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

    /// `~/Library/Application Support/Supervisor/supervisor.pid`
    /// Single-instance lock: the running app writes its pid here on a
    /// successful start and removes it on normal termination. A newcomer
    /// reads it and quits if the recorded pid is a live incumbent (see
    /// SingleInstanceGuard).
    public var pidfilePath: URL {
        appSupportDir.appendingPathComponent("supervisor.pid", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/app-alive.txt`
    /// Touched every ~5s by a Timer on the app's MAIN run loop from the
    /// moment it claims the single-instance lock. Distinct from
    /// heartbeat.txt on purpose: heartbeat freshness means "supervision is
    /// live" (menu-bar health), app-alive freshness means "the main thread
    /// is turning" — which is what a duplicate launch consults to decide
    /// activate-vs-takeover (see DuplicateLaunchPolicy).
    public var appAlivePath: URL {
        appSupportDir.appendingPathComponent("app-alive.txt", isDirectory: false)
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

    /// `~/Library/Application Support/Supervisor/intentional-restart.marker`
    /// Written by the status-bar companion's Restart action IMMEDIATELY before
    /// it terminates the main app, and read by the companion's reparent check
    /// one tick later. Exactly analogous to `selfRebuildMarkerPath`, for the
    /// other deliberate kill.
    ///
    /// Restart escalates to `forceTerminate()` when a hung app ignores the
    /// polite quit, so no SIGTERM handler runs and the companion is orphaned.
    /// Without this marker `reparentAction` saw `getppid() == 1` with no
    /// deploy marker and paged "Supervisor stopped", then "recovered" seconds
    /// later. The page fired for the remedy the previous page had told the
    /// owner to perform, which is the worst possible time to cry wolf.
    ///
    /// Cleared by the relaunched app at startup, same as the self-rebuild
    /// marker. Contents are a timestamp for the trace; only presence decides.
    public var intentionalRestartMarkerPath: URL {
        appSupportDir.appendingPathComponent("intentional-restart.marker", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/companion-incident.marker`
    /// Written by the status-bar companion in the moment it detects the main
    /// app died under it (reparenting to launchd) AND successfully paged the
    /// owner about it. The dying companion cannot also send the recovery page
    /// (it exits immediately), so the marker carries the incident across the
    /// gap: the NEXT companion instance, on its first green tick, sees the
    /// marker, sends the recovery page, and deletes it. Contents are the paged
    /// kind plus a timestamp, for the trace log; only presence is decisive.
    public var companionIncidentMarkerPath: URL {
        appSupportDir.appendingPathComponent("companion-incident.marker", isDirectory: false)
    }

    /// `~/Library/Application Support/Supervisor/companion-page-failed.marker`
    /// The incident marker's dark twin: written when the dying companion's
    /// death page did NOT confirm delivery (failed, no usable webhook, or the
    /// bounded attempt hung), meaning the owner never heard about the outage.
    /// The NEXT companion instance, on its first green tick, sends the one
    /// combined "stopped earlier and has recovered" page and deletes it.
    /// Same contract as the incident marker: contents are for the trace log,
    /// only presence is decisive.
    public var companionFailedPageMarkerPath: URL {
        appSupportDir.appendingPathComponent("companion-page-failed.marker", isDirectory: false)
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
