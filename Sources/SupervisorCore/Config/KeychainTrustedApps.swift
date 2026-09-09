// KeychainTrustedApps.swift — who is allowed to read a Supervisor Keychain
// item that was written from OUTSIDE the app process.
//
// WHY this file exists.
//
// A Keychain item's access control list is decided when the item is CREATED.
// Neither `security add-generic-password -U` nor KeychainAccess's `set()` on
// an existing item rewrites it: both replace the password DATA and leave the
// ACL exactly as the item was born with. So a provider key replaced from a
// shell — `security add-generic-password -s live.supervisor.api.deepseek
// -a api-key -w <value> -A -U` — keeps whatever ACL the ORIGINAL item had.
// Supervisor.app is not in that ACL, so the next launch's key read parks on a
// macOS SecurityAgent prompt, which can sit behind other windows, and
// supervision is blind until a human finds it and clicks Always Allow. That
// is the incident this file is the fix for, and it is the same foreign-ACL
// failure class as the webhook read (audit item A2).
//
// The `-A` ("allow any application") flag does not save an UPDATE either, for
// the same reason: -A is an instruction about the ACL of an item being
// created, and -U does not create one.
//
// So: an external writer has to CREATE the item with the app in its trusted
// list. That means delete-then-add, and it means knowing which paths to
// trust. This type owns the second half.
//
// One honest limit, measured on macOS 15 (2026-09-08). Alongside the trusted
// list, every item carries an ACLAuthorizationPartitionID entry stamped with
// the CREATING program's code identity (`teamid:` for signed code, `cdhash:`
// for ad-hoc). Membership of the trusted list does not bypass it: an item
// created by SupervisorDevTools, with /usr/bin/security explicitly in its
// trusted list, still raised a prompt when /usr/bin/security read it. No
// public API sets the partition list to another program's identity; only the
// `security set-generic-password-partition-list -k <login password>` route
// does, and asking a user for their login password to store an API key is not
// a trade worth making. So the app's FIRST read of an item written out here
// can still cost one Always Allow. That is a different failure from the one
// this file fixes, which was the app not being in the list at all, so every
// launch stalled and no click ever made it stop.

import Foundation

/// The applications an externally-written Supervisor Keychain item grants
/// access to, resolved against what is actually installed on this machine.
public struct KeychainTrustedApps: Sendable, Equatable {
    /// Every path to hand the Security framework (or to pass as `-T`), in the
    /// order they were resolved.
    public let paths: [String]
    /// The Supervisor.app bundles found. These are what put the app in the
    /// item's trusted list, which is the difference between "asked once" and
    /// "asked on every launch, forever".
    public let appBundlePaths: [String]
    /// Supervisor.app bundle paths that were checked and were not there.
    /// Surfaced so a CLI can say WHICH paths it looked at when it found none.
    public let missingAppBundlePaths: [String]

    /// False when no Supervisor.app was found anywhere. The write still goes
    /// ahead (the caller asked for it, and an item only the writer can read is
    /// no worse than what we do today), but the caller must say out loud that
    /// the next app launch will raise a one-time permission prompt.
    public var grantsSupervisorApp: Bool { !appBundlePaths.isEmpty }

    public init(paths: [String], appBundlePaths: [String], missingAppBundlePaths: [String]) {
        self.paths = paths
        self.appBundlePaths = appBundlePaths
        self.missingAppBundlePaths = missingAppBundlePaths
    }
}

public enum KeychainTrustedAppResolver {
    /// Where a released Supervisor lives. INSTALL.md tells every user to drag
    /// the app here, and the app itself refuses to run translocated, so this
    /// is the one path worth hard-coding.
    public static let installedAppPath = "/Applications/Supervisor.app"

    /// `Scripts/build-app.sh` writes the developer bundle here. Trusted too,
    /// because the person running SupervisorDevTools is usually running the
    /// build they just made, not the installed release.
    public static func devBuildAppPath(repoRoot: String) -> String {
        (repoRoot as NSString).appendingPathComponent("build/Supervisor.app")
    }

    /// `/usr/bin/security` is trusted on purpose. Without it, an item written
    /// with an explicit trusted-app list can no longer be read by the repo's
    /// own shell tooling (`Scripts/calibration-key.sh` does a
    /// `find-generic-password -w`) or by a user inspecting their own key, and
    /// each of those reads would raise the very prompt this file exists to
    /// prevent. It is not a meaningful widening: anyone who can run `security`
    /// as this user can already click Allow on the prompt.
    public static let securityCLIPath = "/usr/bin/security"

    /// Resolve the trusted-app list for a write happening outside the app.
    ///
    /// `repoRoot` is the checkout to look for a dev build under; pass nil when
    /// there is no checkout in play. `exists` is injected so the resolution
    /// order can be unit-tested without depending on what happens to be
    /// installed on the machine running the tests.
    public static func resolve(
        repoRoot: String?,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> KeychainTrustedApps {
        var appCandidates = [installedAppPath]
        if let repoRoot, !repoRoot.isEmpty {
            appCandidates.append(devBuildAppPath(repoRoot: repoRoot))
        }
        // Deduplicate while preserving order: a repoRoot of "/" would make the
        // two candidates collide, and a repeated -T is a confusing no-op.
        var seen = Set<String>()
        appCandidates = appCandidates.filter { seen.insert($0).inserted }

        let found = appCandidates.filter(exists)
        let missing = appCandidates.filter { !exists($0) }

        var paths = found
        // Only trust the CLI if it is really there. A -T against a missing
        // path makes `security` fail the whole add, which would turn a
        // cosmetic problem into "the key did not get written".
        if exists(securityCLIPath) {
            paths.append(securityCLIPath)
        }
        return KeychainTrustedApps(
            paths: paths,
            appBundlePaths: found,
            missingAppBundlePaths: missing
        )
    }
}
