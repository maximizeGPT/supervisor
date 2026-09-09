// OnboardingRecordStoreTests.swift
//
// The record is the one bit that tells an upgrade apart from a first run, so
// its read path has to be right in three situations: a machine that wrote one,
// a machine that finished onboarding before the record existed, and a machine
// that has genuinely never run Supervisor. Getting the third wrong would hand
// a brand-new user a one-step "re-grant" screen with no explanation of what
// Supervisor is.

import XCTest
@testable import SupervisorCore

final class OnboardingRecordStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var recordPath: URL { dir.appendingPathComponent("onboarding-record.json") }
    private var dbPath: URL { dir.appendingPathComponent("supervisor.sqlite") }

    func testCleanMachineHasNoRecord() {
        let store = FileOnboardingRecordStore(path: recordPath, priorStateEvidence: [dbPath])
        XCTAssertNil(store.read(), "a first run must not be mistaken for an upgrade")
    }

    func testWriteThenReadRoundTripsVersion() {
        let store = FileOnboardingRecordStore(path: recordPath, priorStateEvidence: [dbPath])
        store.write(OnboardingRecord(completedVersion: "0.4.0"))
        XCTAssertEqual(store.read()?.completedVersion, "0.4.0")
    }

    func testWriteCreatesTheParentDirectory() {
        let nested = dir.appendingPathComponent("does/not/exist/onboarding-record.json")
        let store = FileOnboardingRecordStore(path: nested)
        store.write(OnboardingRecord(completedVersion: "0.4.1"))
        XCTAssertEqual(store.read()?.completedVersion, "0.4.1")
    }

    /// Every install that shipped before this record existed has no file to
    /// read. Without the fallback those users would pay the full five-step
    /// flow one more time before the short path ever kicked in. The database
    /// is created in enterRunningState, which runs only after onboarding
    /// finished or was skipped, so it is sound evidence of a prior install.
    func testPriorDatabaseCountsAsACompletedOnboarding() throws {
        try Data("not really sqlite".utf8).write(to: dbPath)
        let store = FileOnboardingRecordStore(path: recordPath, priorStateEvidence: [dbPath])
        let record = try XCTUnwrap(store.read())
        XCTAssertEqual(record.completedVersion, OnboardingRecord.unknownVersion)
        XCTAssertEqual(record, .inferredFromPriorState)
    }

    /// A truncated or hand-edited record still proves the file was written
    /// once, which only happens after a completed onboarding. Falling back to
    /// "first run" there would be the worse answer.
    func testCorruptRecordIsTreatedAsAPriorInstall() throws {
        try Data("{ this is not json".utf8).write(to: recordPath)
        let store = FileOnboardingRecordStore(path: recordPath)
        XCTAssertEqual(store.read(), .inferredFromPriorState)
    }

    func testStoredRecordWinsOverTheInferenceFallback() throws {
        try Data("not really sqlite".utf8).write(to: dbPath)
        let store = FileOnboardingRecordStore(path: recordPath, priorStateEvidence: [dbPath])
        store.write(OnboardingRecord(completedVersion: "0.4.0"))
        XCTAssertEqual(store.read()?.completedVersion, "0.4.0")
    }

    func testConfigPathsPutsTheRecordInApplicationSupport() {
        let paths = ConfigPaths(home: URL(fileURLWithPath: "/tmp/fake-home"))
        XCTAssertEqual(
            paths.onboardingRecordPath.path,
            "/tmp/fake-home/Library/Application Support/Supervisor/onboarding-record.json"
        )
    }

    // MARK: - Screen Recording, remembered

    func testScreenRecordingFlagRoundTrips() {
        let store = FileOnboardingRecordStore(path: recordPath)
        store.write(OnboardingRecord(completedVersion: "0.4.1", screenRecordingGranted: true))
        XCTAssertEqual(store.read()?.screenRecordingGranted, true)
    }

    /// Records written by 0.4.0 and earlier have no `screenRecordingGranted`
    /// key. Synthesized decoding would reject the whole file, and a rejected
    /// record reads as "never onboarded", which hands a returning user the
    /// five-step flow this change exists to avoid.
    func testRecordWrittenBeforeTheScreenRecordingFieldStillDecodes() throws {
        let legacy = """
        {
          "completedAt" : "2026-07-04T10:00:00Z",
          "completedVersion" : "0.4.0"
        }
        """
        try Data(legacy.utf8).write(to: recordPath)
        let store = FileOnboardingRecordStore(path: recordPath)
        let record = store.read()
        XCTAssertEqual(record?.completedVersion, "0.4.0",
                       "an old record must still be recognized as a completed onboarding")
        XCTAssertEqual(record?.screenRecordingGranted, false,
                       "an absent field must read as 'never granted', so nobody is asked to re-grant what they never had")
    }
}

// MARK: - Launch gate
//
// Which of the two dropped grants opens the onboarding window, and which does
// not. Accessibility always does. Screen Recording does only for a user who
// had it, because asking anyone else to "re-grant" it would be a prompt for
// something they turned down on purpose.
final class OnboardingLaunchGateTests: XCTestCase {

    private func gate(
        hasKey: Bool = true,
        ax: Bool = true,
        screen: Bool = true,
        prior: OnboardingRecord? = nil
    ) -> Bool {
        OnboardingLaunchGate.needsOnboarding(
            hasKey: hasKey,
            axGranted: ax,
            screenRecordingGranted: screen,
            priorInstall: prior
        )
    }

    func testNoKeyAlwaysOpensOnboarding() {
        XCTAssertTrue(gate(hasKey: false, ax: true, screen: true))
        XCTAssertTrue(gate(hasKey: false, ax: false, screen: false,
                           prior: OnboardingRecord(completedVersion: "0.4.0")))
    }

    func testMissingAccessibilityAlwaysOpensOnboarding() {
        XCTAssertTrue(gate(ax: false), "first run")
        XCTAssertTrue(gate(ax: false, prior: OnboardingRecord(completedVersion: "0.4.0")),
                      "upgrade")
    }

    func testEverythingPresentSkipsOnboarding() {
        XCTAssertFalse(gate())
        XCTAssertFalse(gate(prior: OnboardingRecord(completedVersion: "0.4.0",
                                                    screenRecordingGranted: true)))
    }

    /// The branch this gate exists to make reachable: Accessibility survived,
    /// Screen Recording did not, and the user had it before.
    func testLosingOnlyScreenRecordingOpensOnboarding() {
        XCTAssertTrue(gate(
            ax: true,
            screen: false,
            prior: OnboardingRecord(completedVersion: "0.4.0", screenRecordingGranted: true)
        ))
    }

    /// The guard on that branch. Screen Recording is optional and plenty of
    /// users skip it. They must never be dragged back into a window for it.
    func testUserWhoNeverGrantedScreenRecordingIsNotAskedAgain() {
        XCTAssertFalse(gate(
            ax: true,
            screen: false,
            prior: OnboardingRecord(completedVersion: "0.4.0", screenRecordingGranted: false)
        ))
    }

    /// A first run has no record, so a missing Screen Recording cannot open the
    /// window on its own. This is the pin on "first-run behavior is unchanged":
    /// the gate still reduces to `!hasKey || !axGranted`.
    func testFirstRunGateIsUnchanged() {
        for hasKey in [true, false] {
            for ax in [true, false] {
                for screen in [true, false] {
                    XCTAssertEqual(
                        gate(hasKey: hasKey, ax: ax, screen: screen, prior: nil),
                        !hasKey || !ax,
                        "first run (hasKey=\(hasKey) ax=\(ax) screen=\(screen)) must decide exactly as it did before Screen Recording joined the gate"
                    )
                }
            }
        }
    }

    /// An inferred record covers installs that predate the record file. It
    /// cannot know what was granted, so it claims nothing.
    func testInferredRecordDoesNotClaimScreenRecording() {
        XCTAssertFalse(OnboardingRecord.inferredFromPriorState.screenRecordingGranted)
        XCTAssertFalse(gate(ax: true, screen: false, prior: .inferredFromPriorState))
    }
}
