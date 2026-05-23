// SafeRoots.swift — v0.1.4 Part B2 helper.
//
// Paths whose contents a Claude Code session can safely touch even when
// outside the session's cwd, because they're inherently transient or
// machine-local-state scoped. Used by the `edits_outside_worktree`
// rubric category to short-circuit the rubric: an edit under a safe
// root never fires the flag.
//
// Matcher rule (Mohammed-locked, do not "improve" without consulting):
//
//   realpath(candidate).hasPrefix(realpath(safeRoot) + "/")
//
// — with realpath resolved on BOTH sides so /tmp → /private/tmp and
// /var → /private/var don't false-negative, and with a trailing slash
// on the prefix so /tmp doesn't match /tmpfoo (the classic foot-gun
// of plain hasPrefix on directory paths). An exact match against the
// root itself (candidate == realpath(safeRoot)) is also treated as safe.

import Darwin
import Foundation

public enum SafeRoots {

    /// The v0.1.4 default safe-roots list. Each entry is a path Claude Code
    /// can write under without triggering `edits_outside_worktree`.
    ///
    /// **Intentionally absent — DO NOT add without explicit approval:**
    /// - `~/Library/Keychains/` — Supervisor's own API-key Keychain entry
    ///   lives here, and any write to Keychain storage is an explicit
    ///   credential operation that we WANT the rubric to fire on. The
    ///   omission is deliberate; don't future-me-self this back in.
    /// - `~/.cargo/` (all of it) — npm and gem caches stay safe-listed
    ///   because a corrupted cache is locally recoverable (delete + reinstall),
    ///   but a corrupted Cargo cache can wedge builds in ways that require
    ///   manual surgery of the registry index. The failure-mode asymmetry
    ///   is why npm/gem are in and cargo is out.
    /// - `~/.config/`, `~/.local/share/`, `~/.ssh/` — user-scoped state
    ///   that's intentionally personal; the rubric should surface edits
    ///   here.
    /// - `~/Documents`, `~/Desktop` — user content.
    public static var defaults: [String] {
        let home = NSHomeDirectory()
        return [
            "/tmp",
            "/var/tmp",
            "/private/tmp",                                     // macOS realpath of /tmp
            "/private/var/tmp",                                 // macOS realpath of /var/tmp
            home + "/Library/Caches",
            home + "/Library/Logs",                             // transient, write-heavy
            home + "/.cache",                                   // XDG-style
            home + "/.npm",                                     // npm cache + global lock files (recoverable failure)
            home + "/.gem",                                     // ruby gem cache (recoverable failure)
            home + "/Library/Developer/Xcode/DerivedData",
            home + "/Library/Application Support/Code/Cache",   // VS Code-style
        ]
    }

    /// Whether `candidatePath` is under any of `safeRoots`. Both sides
    /// are realpath-resolved so symlinks like /tmp → /private/tmp and
    /// /var → /private/var don't produce false negatives. The trailing-
    /// slash check prevents /tmp matching /tmpfoo.
    public static func isSafe(
        candidate candidatePath: String,
        safeRoots: [String] = SafeRoots.defaults
    ) -> Bool {
        guard let candidateReal = realPath(candidatePath) else { return false }
        for root in safeRoots {
            guard let rootReal = realPath(root) else { continue }
            // Exact-match equality OR strict subpath via "/" boundary.
            if candidateReal == rootReal { return true }
            if candidateReal.hasPrefix(rootReal + "/") { return true }
        }
        return false
    }

    // MARK: - Helpers

    /// Resolve a path via POSIX realpath(3). Returns nil if the path
    /// doesn't exist or resolution fails (caller treats that as "not
    /// safe" — better to false-fire the rubric on a missing path than
    /// to silently mark it safe).
    static func realPath(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buf) != nil {
            return String(cString: buf)
        }
        return nil
    }
}
