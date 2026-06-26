// FixtureCorpus.swift — v0.1.5 calibration corpus type.
//
// Shared fixture struct used by the per-category fixture files. The
// harness in RubricCalibrationTests iterates the combined corpus and
// runs each fixture through live Haiku triage.
//
// FixtureKind.clearPositive / .clearNegative carry pass/fail
// expectations. .adversarial fixtures are graded by characterization,
// not pass/fail — the calibration goal there is to know how Haiku
// handles ambiguity, which is where the rubric's true edges live.

import Foundation
@testable import SupervisorCore

public enum FixtureKind: String, Sendable {
    case clearPositive    // rubric MUST fire targetCategory
    case clearNegative    // rubric MUST NOT fire targetCategory
    case adversarial      // genuine ambiguity; report outcome only
}

public struct CalibrationFixture: Sendable {
    public let name: String
    public let kind: FixtureKind
    public let cwd: String
    public let userPrompt: String
    public let bashCommand: String
    public let bashOutput: String?
    public let bashErrored: Bool
    public let targetCategory: String
    /// For clearPositive only: what severity the rubric expects.
    /// `nil` means we don't enforce severity, just that the category fires.
    public let expectedSeverity: FlagSeverity?
    /// For clearPositive only: what action the rubric expects.
    /// `nil` means we don't enforce action.
    public let expectedAction: FlagAction?

    public init(
        name: String,
        kind: FixtureKind,
        cwd: String,
        userPrompt: String,
        bashCommand: String,
        bashOutput: String? = nil,
        bashErrored: Bool = false,
        targetCategory: String,
        expectedSeverity: FlagSeverity? = nil,
        expectedAction: FlagAction? = nil
    ) {
        self.name = name
        self.kind = kind
        self.cwd = cwd
        self.userPrompt = userPrompt
        self.bashCommand = bashCommand
        self.bashOutput = bashOutput
        self.bashErrored = bashErrored
        self.targetCategory = targetCategory
        self.expectedSeverity = expectedSeverity
        self.expectedAction = expectedAction
    }
}

/// Failure classification — what kind of miscalibration happened on a
/// `clearPositive` or `clearNegative` fixture.
public enum FailureClassification: String, Sendable {
    case falseNegative          // clearPositive: rubric didn't fire
    case falsePositive          // clearNegative: rubric fired when it shouldn't have
    case wrongSeverity          // clearPositive: fired but wrong severity
    case wrongAction            // clearPositive: fired but wrong recommended_action
    case wrongCategory          // clearPositive: fired a DIFFERENT category
    case parseError             // verdict couldn't be parsed
    case apiError               // Anthropic call threw
}

/// One row in the calibration report's `failures` list.
public struct FailureRecord {
    public let fixture: CalibrationFixture
    public let classification: FailureClassification
    public let actualCandidates: [TriageCandidate]
    public let note: String
}

public enum FixtureCorpus {
    public static var all: [CalibrationFixture] {
        DestructiveFixtures.fixtures +
        EditsFixtures.fixtures +
        InjectionFixtures.fixtures
    }
}
