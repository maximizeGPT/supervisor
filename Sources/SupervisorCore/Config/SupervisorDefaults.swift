// SupervisorDefaults.swift — the UserDefaults arm of the SUPERVISOR_HOME seam.
//
// UserDefaults.standard is keyed by bundle/process identity, NOT by home
// directory — so it was the one store the SUPERVISOR_HOME isolation missed:
// an E2E test instance flipping decision sensitivity, the multi-model panel
// opt-in, a panel section's expanded state, or Context Health's once-ever
// nudge flag would silently write the LIVE app's preferences (and vice
// versa: the test would READ the live owner's settings instead of a
// new-user default).
//
// The fix mirrors the rest of the seam: when SUPERVISOR_HOME is set, back
// these prefs with a private suite namespaced by the home's identity hash;
// when it is absent (every production launch), return `.standard` — byte
// identical behavior, same plist, nothing migrates.

import Foundation

public enum SupervisorDefaults {

    /// The store every Supervisor preference read/write should use instead
    /// of `UserDefaults.standard`. Computed per access (it's cheap —
    /// `UserDefaults(suiteName:)` returns a cached instance) so a value is
    /// never captured before the environment is inspected.
    public static var shared: UserDefaults {
        resolve(environment: ProcessInfo.processInfo.environment)
    }

    /// Injectable-environment variant so tests can assert the routing
    /// without `setenv` (ProcessInfo caches its environment snapshot on
    /// first access, so an in-test `setenv` is not reliably visible).
    public static func resolve(environment: [String: String]) -> UserDefaults {
        guard let home = environment["SUPERVISOR_HOME"], !home.isEmpty else {
            return .standard
        }
        // Suite per fake home (not one shared test suite): two concurrent
        // harness runs with different RUN_IDs must not see each other's
        // prefs any more than they see each other's sqlite.
        return UserDefaults(suiteName: suiteName(forHomePath: home)) ?? .standard
    }

    /// Pure name derivation for tests: `live.supervisor.e2e.<12-hex-hash>`.
    public static func suiteName(forHomePath path: String) -> String {
        "live.supervisor.e2e." + ConfigPaths.identityHash(forHomePath: path)
    }
}
