// DuplicateLaunchPolicy.swift
//
// What a duplicate launch should DO once SingleInstanceGuard says a live
// incumbent holds the flock. The guard answers "is the lock held"; this
// answers "is the holder actually supervising".
//
// Why this exists: the v0.3.0 duplicate path was an unconditional silent
// exit(0). Correct when the incumbent is healthy — but when the incumbent is
// alive-and-hung (blocked on a Keychain SecurityAgent prompt before any UI,
// a zombie that claimed the lock and then bailed before presenting the
// hover), every relaunch silently vanished while an invisible process kept
// the flock. The kernel only releases a flock on process death, so the only
// user-discoverable fix was a reboot. Real user report, v0.3.0 release week:
// "sometimes opens, sometimes doesn't; I've had to restart my laptop."
//
// The policy is decided from the incumbent's app-alive marker age. The
// marker (app-alive.txt) is touched every ~5s by a Timer on the incumbent's
// MAIN run loop, starting the moment it claims the lock — so its freshness
// measures exactly the thing a takeover decision needs: "is the incumbent's
// main thread responsive". Heartbeat.txt was the wrong signal here: it
// measures supervision health (it only exists once the engine runs), so it
// wrongly condemned healthy incumbents sitting in onboarding and
// milliseconds-old launch winners that hadn't reached running state yet.
//
//   - fresh marker     -> the incumbent's run loop is alive (running,
//     onboarding, whatever). Ask it to surface itself (so the launch is
//     never a silent no-op for the user) and quit.
//   - stale or missing -> the incumbent holds the lock but its main thread
//     is not turning (hung on a pre-UI Keychain prompt, zombie, or a
//     pre-marker app version). Terminate it and take over; the user's
//     launch intent wins over a wedged process.
//
// Pure function, no I/O: the app supplies the marker age, tests drive
// every branch directly. The app also gives a takeover verdict a ~2s grace
// re-check so a winner that claimed the lock microseconds ago has time to
// write its first touch.

import Foundation

public enum DuplicateLaunchPolicy {

    /// Same 30s threshold as the menu-bar honest-health window: a main run
    /// loop that hasn't turned in 30s (the beat writes every ~5s) is hung by
    /// every standard the product already uses.
    public static let stalenessWindow: TimeInterval = 30

    public enum Action: Equatable {
        /// Incumbent's run loop is alive: ask it to surface its UI
        /// (distributed notification), then this duplicate exits quietly.
        case activateIncumbentAndQuit
        /// Incumbent holds the lock but its main thread is not turning
        /// (hung pre-UI, zombie, pre-marker version): terminate it and
        /// take over the launch.
        case takeOver(reason: String)
    }

    /// - Parameter appAliveAge: seconds since app-alive.txt was last
    ///   touched, or nil when the file does not exist.
    public static func decide(
        appAliveAge: TimeInterval?,
        stalenessWindow: TimeInterval = DuplicateLaunchPolicy.stalenessWindow
    ) -> Action {
        guard let age = appAliveAge else {
            return .takeOver(reason: "incumbent holds the lock but has no app-alive marker (hung before its first beat, or a pre-marker version)")
        }
        if age > stalenessWindow {
            return .takeOver(reason: "incumbent app-alive marker is \(Int(age))s old (staleness window \(Int(stalenessWindow))s)")
        }
        return .activateIncumbentAndQuit
    }

    /// The cross-process "surface yourself" signal a healthy incumbent
    /// listens for. Posted by the quitting duplicate so a second click on
    /// Supervisor.app is never a silent no-op: the running instance
    /// re-presents its hover instead.
    ///
    /// Namespaced by the resolved home's identity hash because a
    /// DistributedNotification is MACHINE-global: with a bare name, an E2E
    /// test instance's duplicate (s11) would ping the LIVE app — a focus
    /// steal on every harness run. Poster and observer both compute this at
    /// their own launch, so the two processes of one instance (same
    /// SUPERVISOR_HOME, or both unset) always agree, while test and live
    /// instances land on different names and never cross.
    public static var activateNotification: String {
        activateNotification(homePath: ConfigPaths.resolvedHome.path)
    }

    /// Pure variant for tests: `live.supervisor.activate.<12-hex-of-sha256(home)>`.
    public static func activateNotification(homePath: String) -> String {
        "live.supervisor.activate." + ConfigPaths.identityHash(forHomePath: homePath)
    }
}
