// TrustedAppKeychainWriter.swift — replace a Keychain item from outside the
// app so that Supervisor.app is named in the item's access list rather than
// locked out of it. (KeychainTrustedApps records the one prompt this still
// cannot remove and why.)
//
// The ACL of a Keychain item is fixed at creation (see KeychainTrustedApps for
// the full WHY). Updating in place keeps the old ACL, so the only way to fix
// or to establish one is delete-then-add. Delete-then-add has an obvious
// hazard: if the add fails after the delete succeeded, the user is left with
// NO key at all and a supervisor that quietly stops watching.
//
// The ordering below cannot produce that outcome. The new value is written to
// a STAGING account under the same service first. That proves an add with this
// ACL succeeds on this machine before anything is destroyed, and it keeps a
// second copy of the new value alive across the delete. Only then is the real
// item deleted and rewritten; if that rewrite still fails, the previous value
// (when it was readable) is put back, and the staged copy is deliberately left
// behind with its account named in the error so nothing has to be retyped.
//
// The staging round trip is cheap in the currency that matters here. Creating
// a new item and deleting one are authorized without asking the user; it is
// reading, and updating in place, an item whose ACL excludes the caller that
// summons SecurityAgent. So staging adds a write and a delete, not a prompt.

import Foundation

/// The three primitives the writer needs. A protocol so the ordering above can
/// be tested against a fake, with no login Keychain anywhere near the tests.
public protocol KeychainItemOps: Sendable {
    func read(service: String, account: String) throws -> String?
    func deleteIfPresent(service: String, account: String) throws
    func add(
        service: String,
        account: String,
        value: String,
        label: String,
        trustedAppPaths: [String]
    ) throws
}

public struct TrustedAppKeychainWriter: Sendable {

    /// Every step the writer can take, recorded in the order taken. Exposed so
    /// a test can assert the ordering property directly rather than inferring
    /// it from the final state.
    public enum Step: String, Sendable, Equatable {
        case backupRead
        case stageAdd
        case deleteReal
        case addReal
        case deleteStaging
        case restorePrevious
    }

    public struct Outcome: Sendable, Equatable {
        public let steps: [Step]
        /// An item was already there.
        public let hadPreviousItem: Bool
        /// The previous value could be read, so it could have been restored.
        /// False when the item was there but its ACL locked us out — which is
        /// exactly the state this writer is usually called to repair.
        public let previousValueWasReadable: Bool
        /// The staged copy could not be cleaned up. Harmless (it holds the
        /// same value that was just written) but worth reporting.
        public let stagingLeftBehind: Bool
    }

    public struct Failure: Error, Sendable {
        public let underlying: String
        public let steps: [TrustedAppKeychainWriter.Step]
        /// The previous value was put back, so the user still has the key they
        /// had before this call.
        public let restoredPreviousValue: Bool
        /// The new value is still sitting in the staging item, under this
        /// account, and can be recovered by hand.
        public let stagedRecoveryAccount: String?
        /// True only when nothing at all is left: no previous value restored
        /// and no staged copy. Reaching this requires the FIRST add to fail,
        /// in which case the real item was never touched, so it still means
        /// "nothing was lost" — it means "nothing was written".
        public let nothingWasWritten: Bool
    }

    /// Suffix appended to the account name for the staging item.
    public static let stagingAccountSuffix = ".supervisor-acl-staging"

    private let ops: KeychainItemOps

    public init(ops: KeychainItemOps) {
        self.ops = ops
    }

    /// Create (never update) `service`/`account` holding `value`, with an ACL
    /// that trusts `trustedApps.paths`.
    @discardableResult
    public func replace(
        service: String,
        account: String,
        value: String,
        label: String,
        trustedApps: KeychainTrustedApps
    ) throws -> Outcome {
        var steps: [Step] = []
        let stagingAccount = account + Self.stagingAccountSuffix

        // 1. Best-effort backup. A throw here is INFORMATION, not a failure:
        //    an unreadable existing item is the foreign-ACL state we are here
        //    to repair, and refusing to proceed would make the repair
        //    impossible. It only costs us the ability to restore.
        steps.append(.backupRead)
        var previous: String?
        var previousReadable = true
        do {
            previous = try ops.read(service: service, account: account)
        } catch {
            previous = nil
            previousReadable = false
        }
        // An item we could not read may or may not exist. Treat "unreadable"
        // as "probably there", so the outcome never claims a clean slate it
        // cannot vouch for.
        let hadPrevious = (previous != nil) || !previousReadable

        // 2. Stage the new value. Nothing has been destroyed yet, so a failure
        //    here is a clean abort.
        steps.append(.stageAdd)
        do {
            try ops.deleteIfPresent(service: service, account: stagingAccount)
            try ops.add(
                service: service,
                account: stagingAccount,
                value: value,
                label: label + " (staging)",
                trustedAppPaths: trustedApps.paths
            )
        } catch {
            throw Failure(
                underlying: "\(error)",
                steps: steps,
                restoredPreviousValue: false,
                stagedRecoveryAccount: nil,
                nothingWasWritten: true
            )
        }

        // 3. Destroy and recreate the real item. The staged copy is alive for
        //    the whole of this window.
        steps.append(.deleteReal)
        do {
            try ops.deleteIfPresent(service: service, account: account)
        } catch {
            // Could not delete, so could not fix the ACL. The item is
            // untouched and the staged copy is still ours to clean up.
            try? ops.deleteIfPresent(service: service, account: stagingAccount)
            throw Failure(
                underlying: "\(error)",
                steps: steps,
                restoredPreviousValue: false,
                stagedRecoveryAccount: nil,
                nothingWasWritten: true
            )
        }

        steps.append(.addReal)
        do {
            try ops.add(
                service: service,
                account: account,
                value: value,
                label: label,
                trustedAppPaths: trustedApps.paths
            )
        } catch {
            // The real slot is empty right now. Put the old value back if we
            // have it, and leave the staged copy standing either way.
            var restored = false
            if let previous {
                steps.append(.restorePrevious)
                do {
                    try ops.add(
                        service: service,
                        account: account,
                        value: previous,
                        label: label,
                        trustedAppPaths: trustedApps.paths
                    )
                    restored = true
                } catch {
                    // Both adds failed, so the slot stays empty. The staged
                    // copy below is what keeps the new value recoverable.
                    restored = false
                }
            }
            throw Failure(
                underlying: "\(error)",
                steps: steps,
                restoredPreviousValue: restored,
                stagedRecoveryAccount: stagingAccount,
                nothingWasWritten: false
            )
        }

        // 4. Clean up. A failure here leaves a duplicate of a value that was
        //    just written successfully, so it is reported, not thrown.
        steps.append(.deleteStaging)
        var stagingLeftBehind = false
        do {
            try ops.deleteIfPresent(service: service, account: stagingAccount)
        } catch {
            stagingLeftBehind = true
        }

        return Outcome(
            steps: steps,
            hadPreviousItem: hadPrevious,
            previousValueWasReadable: previousReadable,
            stagingLeftBehind: stagingLeftBehind
        )
    }
}
