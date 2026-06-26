// RuntimeToggles.swift — owner-facing on/off switches the running app reads live.
//
// Each toggle is a marker file under Application Support/Supervisor (existence =
// ON), so flipping one takes effect WITHOUT a rebuild and survives a relaunch.
// Mirrors the established `TriageEngine.autoDispatchDisabled` pattern. The hover
// panel's buttons call the setters; the LoopController / TriageEngine read the
// getters on their hot paths.
//
// Reads are `nonisolated static` so any actor/thread can consult them cheaply.

import Foundation

public enum RuntimeToggles {

    private static var markerDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Supervisor", isDirectory: true)
    }

    /// `dir` defaults to the real Application Support marker dir; tests pass a
    /// temp dir so a round-trip never creates a real marker the running app
    /// would pick up.
    nonisolated static func isOn(_ name: String, dir: URL? = nil) -> Bool {
        let base = dir ?? markerDir
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path)
    }

    static func setOn(_ name: String, _ on: Bool, dir: URL? = nil) {
        let base = dir ?? markerDir
        let url = base.appendingPathComponent(name)
        if on {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 4-hour loop cap

    /// When ON, the LoopController's 4-hour wall-clock hard stop is DISABLED — the
    /// loop runs as long as it stays productive (for long sessions / the
    /// give-it-one-prompt screen-record demo). The other stops still apply: a
    /// kill, three-consecutive-low, and the pause-on-user-message are unaffected.
    nonisolated public static var loopCapDisabled: Bool { isOn(loopCapMarker) }
    public static func setLoopCapDisabled(_ on: Bool) { setOn(loopCapMarker, on) }
    private static let loopCapMarker = "loop-cap-disabled.marker"

    // MARK: - Owner-presence backoff (demo switch)

    /// When ON, the LoopController's owner-presence backoff is DISABLED — the drive
    /// loop dispatches the moment a session goes idle, instead of waiting for the
    /// operator to go quiet for the backoff window. For the give-it-one-prompt
    /// screen-record demo, where the operator IS present but wants to SEE the loop
    /// drive right away. OFF in normal use (so the loop never types over a present,
    /// actively-steering operator).
    nonisolated public static var ownerPresenceBackoffDisabled: Bool { isOn(presenceBackoffMarker) }
    public static func setOwnerPresenceBackoffDisabled(_ on: Bool) { setOn(presenceBackoffMarker, on) }
    private static let presenceBackoffMarker = "owner-presence-backoff-disabled.marker"

    // MARK: - Global pause

    /// When ON, Supervisor is globally PAUSED — the engine processes no events:
    /// no triage, no dispatch, no inject, no API spend. The watcher goes dormant
    /// (not gone) and resumes the moment it's turned back off. Distinct from
    /// `autoDispatchDisabled` (which only silences the continue/dispatch path).
    nonisolated public static var supervisorPaused: Bool { isOn(pausedMarker) }
    public static func setSupervisorPaused(_ on: Bool) { setOn(pausedMarker, on) }
    private static let pausedMarker = "supervisor-paused.marker"
}
