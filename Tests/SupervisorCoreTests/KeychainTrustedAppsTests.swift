// KeychainTrustedAppsTests.swift
//
// Covers the fix for the foreign-ACL launch stall: a provider key written from
// outside the app (`security add-generic-password ... -A -U`, or any tool
// using KeychainAccess) left Supervisor.app out of the item's ACL, so the next
// launch parked on a SecurityAgent prompt and supervision went blind.
//
// Nothing here touches the real login Keychain or any live.supervisor.api.*
// item: the resolver takes an injected `exists`, and the writer takes an
// injected `KeychainItemOps`.

import XCTest
@testable import SupervisorCore

final class KeychainTrustedAppsTests: XCTestCase {

    // MARK: - Trusted-app resolution (the "-T is present" half)

    func testInstalledAppIsTrustedWhenItExists() {
        let apps = KeychainTrustedAppResolver.resolve(repoRoot: nil) { path in
            path == KeychainTrustedAppResolver.installedAppPath
                || path == KeychainTrustedAppResolver.securityCLIPath
        }
        XCTAssertTrue(apps.paths.contains("/Applications/Supervisor.app"))
        XCTAssertEqual(apps.appBundlePaths, ["/Applications/Supervisor.app"])
        XCTAssertTrue(apps.grantsSupervisorApp)
        XCTAssertTrue(apps.missingAppBundlePaths.isEmpty)
    }

    func testDevBuildBundleIsAlsoTrustedWhenItExists() {
        let repo = "/Users/dev/supervisor"
        let devPath = repo + "/build/Supervisor.app"
        let apps = KeychainTrustedAppResolver.resolve(repoRoot: repo) { path in
            path == devPath || path == KeychainTrustedAppResolver.securityCLIPath
        }
        XCTAssertEqual(apps.appBundlePaths, [devPath])
        XCTAssertTrue(apps.grantsSupervisorApp)
        // The installed path was checked and is honestly reported as absent,
        // so a CLI can name what it looked at.
        XCTAssertEqual(apps.missingAppBundlePaths, ["/Applications/Supervisor.app"])
    }

    func testBothBundlesAreTrustedInInstalledThenDevOrder() {
        let repo = "/Users/dev/supervisor"
        let apps = KeychainTrustedAppResolver.resolve(repoRoot: repo) { _ in true }
        XCTAssertEqual(apps.appBundlePaths, [
            "/Applications/Supervisor.app",
            repo + "/build/Supervisor.app",
        ])
    }

    func testNoAppBundleAnywhereIsReportedButDoesNotEmptyTheTrustedList() {
        let apps = KeychainTrustedAppResolver.resolve(repoRoot: "/Users/dev/supervisor") { path in
            path == KeychainTrustedAppResolver.securityCLIPath
        }
        XCTAssertFalse(apps.grantsSupervisorApp)
        XCTAssertEqual(apps.missingAppBundlePaths.count, 2)
        // Still write something usable: the CLI stays trusted so the repo's own
        // tooling can read the item back.
        XCTAssertEqual(apps.paths, ["/usr/bin/security"])
    }

    func testSecurityCLIStaysTrustedSoRepoToolingDoesNotStartPrompting() {
        // Scripts/calibration-key.sh reads these services with
        // `security find-generic-password -w`. Dropping /usr/bin/security from
        // the ACL would turn that read into the very prompt this change exists
        // to remove.
        let apps = KeychainTrustedAppResolver.resolve(repoRoot: nil) { _ in true }
        XCTAssertTrue(apps.paths.contains("/usr/bin/security"))
    }

    func testAMissingSecurityBinaryIsNotTrusted() {
        // A -T against a path that is not there makes `security`/SecAccess fail
        // the whole add, which would turn a cosmetic problem into a lost key.
        let apps = KeychainTrustedAppResolver.resolve(repoRoot: nil) { path in
            path == KeychainTrustedAppResolver.installedAppPath
        }
        XCTAssertEqual(apps.paths, ["/Applications/Supervisor.app"])
    }

    func testNoPathIsTrustedTwice() {
        // A repeated -T is a confusing no-op, and a duplicated SecTrustedApplication
        // makes the resulting ACL harder to read in Keychain Access.
        let apps = KeychainTrustedAppResolver.resolve(repoRoot: "/Users/dev/supervisor") { _ in true }
        XCTAssertEqual(Set(apps.paths).count, apps.paths.count)
    }

    // MARK: - Writer ordering (the "cannot lose the only key" half)

    private let service = "test.supervisor.acl.example"
    private let account = "api-key"

    private func trustedApps() -> KeychainTrustedApps {
        KeychainTrustedAppResolver.resolve(repoRoot: nil) { _ in true }
    }

    func testTheCreatedItemCarriesTheTrustedAppPaths() throws {
        let ops = RecordingKeychainItemOps()
        let outcome = try TrustedAppKeychainWriter(ops: ops).replace(
            service: service, account: account, value: "new-key",
            label: "Supervisor Test Key", trustedApps: trustedApps()
        )
        XCTAssertEqual(ops.stored(service: service, account: account), "new-key")
        XCTAssertFalse(outcome.hadPreviousItem)

        let realAdd = try XCTUnwrap(ops.calls.last { $0.kind == "add" && $0.account == account })
        XCTAssertTrue(realAdd.trustedAppPaths.contains("/Applications/Supervisor.app"),
                      "the app must be in the ACL of an item written from outside the app")
        XCTAssertTrue(realAdd.trustedAppPaths.contains("/usr/bin/security"))
    }

    func testTheNewValueIsStagedBeforeTheRealItemIsDeleted() throws {
        let ops = RecordingKeychainItemOps(initial: ["\(service)|\(account)": "old-key"])
        let outcome = try TrustedAppKeychainWriter(ops: ops).replace(
            service: service, account: account, value: "new-key",
            label: "Supervisor Test Key", trustedApps: trustedApps()
        )
        XCTAssertEqual(outcome.steps, [.backupRead, .stageAdd, .deleteReal, .addReal, .deleteStaging])
        let stageIndex = try XCTUnwrap(outcome.steps.firstIndex(of: .stageAdd))
        let deleteIndex = try XCTUnwrap(outcome.steps.firstIndex(of: .deleteReal))
        XCTAssertLessThan(stageIndex, deleteIndex,
                          "nothing may be destroyed before an add with this ACL is proven to work")
        XCTAssertTrue(outcome.hadPreviousItem)
        XCTAssertTrue(outcome.previousValueWasReadable)
        XCTAssertFalse(outcome.stagingLeftBehind)
        // The staging item is not left lying around on the happy path.
        XCTAssertNil(ops.stored(service: service, account: account + TrustedAppKeychainWriter.stagingAccountSuffix))
    }

    func testAFailedStagingAddLeavesTheExistingKeyUntouched() {
        let ops = RecordingKeychainItemOps(initial: ["\(service)|\(account)": "old-key"])
        ops.failAddForAccounts = [account + TrustedAppKeychainWriter.stagingAccountSuffix]
        XCTAssertThrowsError(try TrustedAppKeychainWriter(ops: ops).replace(
            service: service, account: account, value: "new-key",
            label: "Supervisor Test Key", trustedApps: trustedApps()
        )) { error in
            let failure = error as? TrustedAppKeychainWriter.Failure
            XCTAssertEqual(failure?.nothingWasWritten, true)
            XCTAssertFalse(failure?.steps.contains(.deleteReal) ?? true,
                           "the real item must never be deleted when the staging add failed")
        }
        XCTAssertEqual(ops.stored(service: service, account: account), "old-key")
    }

    func testAnUnrecoverableRealAddStillLeavesTheNewValueRecoverable() {
        // Worst case: every add to the real account fails, so even the restore
        // cannot land. The staged copy is then the safety net, and its account
        // name is reported so the value can be recovered by hand instead of
        // retyped from a secret the user may no longer have.
        let ops = RecordingKeychainItemOps(initial: ["\(service)|\(account)": "old-key"])
        ops.failAddForAccounts = [account]
        let staging = account + TrustedAppKeychainWriter.stagingAccountSuffix
        XCTAssertThrowsError(try TrustedAppKeychainWriter(ops: ops).replace(
            service: service, account: account, value: "new-key",
            label: "Supervisor Test Key", trustedApps: trustedApps()
        )) { error in
            let failure = error as? TrustedAppKeychainWriter.Failure
            XCTAssertEqual(failure?.restoredPreviousValue, false)
            XCTAssertEqual(failure?.nothingWasWritten, false)
            XCTAssertEqual(failure?.stagedRecoveryAccount, staging)
            XCTAssertEqual(failure?.steps.last, TrustedAppKeychainWriter.Step.restorePrevious)
        }
        XCTAssertEqual(ops.stored(service: service, account: staging), "new-key",
                       "the staged copy must survive a failed rewrite")
    }

    func testAFailedRealAddWithARestorableBackupEndsWithAKeyInPlace() {
        // Only the FIRST add of the real account fails, which is the realistic
        // transient case. The restore then succeeds and the user still has a key.
        final class FailFirstRealAdd: KeychainItemOps, @unchecked Sendable {
            let inner = RecordingKeychainItemOps(initial: ["svc|api-key": "old-key"])
            var realAdds = 0
            struct Boom: Error {}
            func read(service: String, account: String) throws -> String? {
                try inner.read(service: service, account: account)
            }
            func deleteIfPresent(service: String, account: String) throws {
                try inner.deleteIfPresent(service: service, account: account)
            }
            func add(service: String, account: String, value: String, label: String, trustedAppPaths: [String]) throws {
                if account == "api-key" {
                    realAdds += 1
                    if realAdds == 1 { throw Boom() }
                }
                try inner.add(service: service, account: account, value: value, label: label, trustedAppPaths: trustedAppPaths)
            }
        }
        let ops = FailFirstRealAdd()
        XCTAssertThrowsError(try TrustedAppKeychainWriter(ops: ops).replace(
            service: "svc", account: "api-key", value: "new-key",
            label: "Supervisor Test Key", trustedApps: trustedApps()
        )) { error in
            XCTAssertEqual((error as? TrustedAppKeychainWriter.Failure)?.restoredPreviousValue, true)
        }
        XCTAssertEqual(ops.inner.stored(service: "svc", account: "api-key"), "old-key",
                       "a failed add after a successful delete must not leave the user with no key")
    }

    func testAnUnreadableExistingItemIsStillRepaired() throws {
        // The incident's state: the item is there, its ACL locks everyone out,
        // and it therefore cannot be backed up. Refusing to proceed would make
        // the item unrepairable, so the write goes ahead and says so.
        let ops = RecordingKeychainItemOps(initial: ["\(service)|\(account)": "unreadable"])
        ops.readThrows = true
        let outcome = try TrustedAppKeychainWriter(ops: ops).replace(
            service: service, account: account, value: "new-key",
            label: "Supervisor Test Key", trustedApps: trustedApps()
        )
        XCTAssertTrue(outcome.hadPreviousItem)
        XCTAssertFalse(outcome.previousValueWasReadable)
        XCTAssertEqual(ops.stored(service: service, account: account), "new-key")
    }

    func testAFailedRealDeleteAbortsWithoutTouchingTheItem() {
        let ops = RecordingKeychainItemOps(initial: ["\(service)|\(account)": "old-key"])
        ops.failDeleteForAccounts = [account]
        XCTAssertThrowsError(try TrustedAppKeychainWriter(ops: ops).replace(
            service: service, account: account, value: "new-key",
            label: "Supervisor Test Key", trustedApps: trustedApps()
        )) { error in
            XCTAssertEqual((error as? TrustedAppKeychainWriter.Failure)?.nothingWasWritten, true)
        }
        XCTAssertEqual(ops.stored(service: service, account: account), "old-key")
    }
}
