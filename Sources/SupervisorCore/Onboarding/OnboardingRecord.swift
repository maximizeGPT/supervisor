// OnboardingRecord.swift
//
// "Has this machine ever finished onboarding?" — the one bit that separates a
// genuine first run from an upgrade that lost a macOS permission.
//
// Why it exists: macOS keys an Accessibility grant to the bundle id AND the
// app's designated requirement, which names the signing certificate. When the
// certificate changes between two installs, the grant does not carry, the app
// launches with axOK=false, and the returning user is dropped back into
// onboarding. Without this record the app cannot tell that user apart from
// somebody who has never run Supervisor, so it walks them through all five
// steps again. With it, OnboardingViewModel shows only the permission that is
// actually missing. See docs/upgrading.md for the full story.

import Foundation

/// What a completed onboarding leaves behind.
public struct OnboardingRecord: Codable, Sendable, Equatable {

    /// The app version that last completed (or skipped past) onboarding.
    /// `Self.unknownVersion` when the record was inferred from older state
    /// rather than read from disk.
    public var completedVersion: String

    /// When that happened. `.distantPast` for an inferred record.
    public var completedAt: Date

    /// Whether Screen Recording was granted the last time the app ran cleanly.
    /// Accessibility is not stored alongside it because the launch gate always
    /// asks for Accessibility when it is missing; Screen Recording is optional,
    /// so "missing" only means something was lost when the user had it before.
    /// Defaults to false, including for records written before this field
    /// existed, so nobody is dragged into a re-grant they never earned.
    public var screenRecordingGranted: Bool

    /// Stand-in version for an install that predates this record existing.
    public static let unknownVersion = "unknown"

    public init(
        completedVersion: String,
        completedAt: Date = Date(),
        screenRecordingGranted: Bool = false
    ) {
        self.completedVersion = completedVersion
        self.completedAt = completedAt
        self.screenRecordingGranted = screenRecordingGranted
    }

    /// The record we synthesize for an install that finished onboarding before
    /// this file was ever written. See `FileOnboardingRecordStore`.
    public static let inferredFromPriorState = OnboardingRecord(
        completedVersion: unknownVersion,
        completedAt: .distantPast
    )

    // Records written by 0.4.0 and earlier have no `screenRecordingGranted`
    // key. Synthesized decoding would reject those files outright, and a
    // rejected record reads as "never onboarded", which is the five-step flow
    // this whole change exists to avoid. Decode it as absent instead.
    private enum CodingKeys: String, CodingKey {
        case completedVersion, completedAt, screenRecordingGranted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completedVersion = try c.decode(String.self, forKey: .completedVersion)
        completedAt = try c.decode(Date.self, forKey: .completedAt)
        screenRecordingGranted =
            try c.decodeIfPresent(Bool.self, forKey: .screenRecordingGranted) ?? false
    }
}

// MARK: - Launch gate

/// Should the app open the onboarding window at launch, and if so, why?
///
/// This lives in Core, away from `main.swift`, because it is the decision the
/// re-grant flow hangs off: `OnboardingViewModel` can only route a user to the
/// one-step Screen Recording re-grant if something opened the window for that
/// reason in the first place. Pure and total, so every branch is testable.
public enum OnboardingLaunchGate {

    /// - Parameters:
    ///   - hasKey: a provider key is stored for the active provider.
    ///   - axGranted: macOS reports Accessibility for this process.
    ///   - screenRecordingGranted: macOS reports Screen Recording.
    ///   - priorInstall: what a previously completed onboarding left behind.
    /// - Returns: true when the onboarding window should open.
    public static func needsOnboarding(
        hasKey: Bool,
        axGranted: Bool,
        screenRecordingGranted: Bool,
        priorInstall: OnboardingRecord?
    ) -> Bool {
        // First run, or a user who wiped their key: unchanged since v0.1.0.
        if !hasKey { return true }
        // Accessibility is what Supervisor needs to act, so its absence always
        // opens the window, on a first run and on an upgrade alike.
        if !axGranted { return true }
        // Screen Recording is optional, and asking a user who never granted it
        // to "re-grant" would be a prompt for something they declined on
        // purpose. Only a user who HAD it and lost it is routed back, which is
        // the same signing-identity change that takes Accessibility. Skipping
        // that step records the permission as absent again, so the window does
        // not reopen on the next launch.
        if let prior = priorInstall, prior.screenRecordingGranted, !screenRecordingGranted {
            return true
        }
        return false
    }
}

/// Read/write seam so the view model and the app can be tested without disk.
public protocol OnboardingRecordStore: Sendable {
    /// The record for a previously completed onboarding, or nil on a machine
    /// that has never finished one.
    func read() -> OnboardingRecord?
    /// Persist a completion. Best-effort: a failed write costs a longer
    /// onboarding next upgrade, never a broken launch, so it never throws.
    func write(_ record: OnboardingRecord)
}

/// Disk-backed store: a small JSON file in Application Support.
public struct FileOnboardingRecordStore: OnboardingRecordStore {

    private let path: URL
    private let priorStateEvidence: [URL]

    /// - Parameters:
    ///   - path: where the record lives (`ConfigPaths.onboardingRecordPath`).
    ///   - priorStateEvidence: paths that only a COMPLETED onboarding could
    ///     have produced. Every install that shipped before this record
    ///     existed has no file to read, and without this fallback those users
    ///     would pay the full five-step flow one more time before the short
    ///     path ever kicked in. The app passes `ConfigPaths.databasePath`:
    ///     the SQLite file is created in `enterRunningState`, which runs only
    ///     after onboarding finished or was skipped, so its presence is a
    ///     sound proxy. A user who quits midway through a genuine first run
    ///     has no database, and correctly gets the full flow.
    public init(path: URL, priorStateEvidence: [URL] = []) {
        self.path = path
        self.priorStateEvidence = priorStateEvidence
    }

    public func read() -> OnboardingRecord? {
        if let data = try? Data(contentsOf: path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let record = try? decoder.decode(OnboardingRecord.self, from: data) {
                return record
            }
            // A corrupt record is still evidence the file was written once,
            // which only happens after a completed onboarding.
            return .inferredFromPriorState
        }
        let fm = FileManager.default
        if priorStateEvidence.contains(where: { fm.fileExists(atPath: $0.path) }) {
            return .inferredFromPriorState
        }
        return nil
    }

    public func write(_ record: OnboardingRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: path, options: .atomic)
    }
}

/// Test double.
public final class InMemoryOnboardingRecordStore: OnboardingRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: OnboardingRecord?

    public init(record: OnboardingRecord? = nil) {
        self.record = record
    }

    public func read() -> OnboardingRecord? {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    public func write(_ record: OnboardingRecord) {
        lock.lock(); defer { lock.unlock() }
        self.record = record
    }
}
