// DecisionSensitivityTests.swift - v0.2.0 (Reddit feedback E).
//
// The decision-sensitivity setting is the owner's act-vs-ask dial. These tests
// pin the load-bearing contract:
//   - Balanced (the default) maps to EXACTLY today's thresholds, so a fresh
//     install behaves identically to before this setting existed: the evaluator
//     pass threshold equals Evaluator.defaultThreshold (0.8) and the auto-answer
//     act-bar is .medium (the prior `confidence == .low` degrade).
//   - The dial moves monotonically: cautious raises the evaluator bar + tightens
//     the answer bar to .high; decisive lowers the evaluator bar.
//   - The persisted store round-trips through an injected UserDefaults suite (so
//     the test never touches the app's real .standard domain) and defaults to
//     .balanced on an empty / unknown value.
//   - The confidence ordering helper (.low < .medium < .high, `meets`) is the
//     primitive the engine's answer gate uses; it is exercised directly.

import XCTest
@testable import SupervisorCore

final class DecisionSensitivityTests: XCTestCase {

    // MARK: - Balanced == today's behavior (the default must not change anything)

    func testBalancedEvaluatorThresholdEqualsDefault() {
        XCTAssertEqual(
            DecisionSensitivity.balanced.evaluatorPassThreshold,
            Evaluator.defaultThreshold,
            "Balanced must equal the existing evaluator default (0.8) so the planner loop grades identically"
        )
    }

    func testBalancedAnswerBarIsMedium() {
        // Today's engine degrades only LOW-confidence answers; that is exactly a
        // .medium act-bar (medium and high inject, low escalates).
        XCTAssertEqual(DecisionSensitivity.balanced.minAnswerConfidenceToInject, .medium)
    }

    func testStoreDefaultsToBalancedOnEmptyDomain() {
        let defaults = isolatedDefaults()
        XCTAssertEqual(DecisionSensitivityStore.current(defaults: defaults), .balanced,
                       "no stored value -> Balanced (the unchanged default)")
    }

    // MARK: - The dial moves the gates in the right direction

    func testCautiousRaisesEvaluatorBarAndTightensAnswerBar() {
        XCTAssertGreaterThan(
            DecisionSensitivity.cautious.evaluatorPassThreshold,
            DecisionSensitivity.balanced.evaluatorPassThreshold,
            "cautious must raise the pass bar (redirect/retry more)"
        )
        XCTAssertEqual(DecisionSensitivity.cautious.minAnswerConfidenceToInject, .high,
                       "cautious only injects the surest answers; medium escalates to the human")
    }

    func testDecisiveLowersEvaluatorBar() {
        XCTAssertLessThan(
            DecisionSensitivity.decisive.evaluatorPassThreshold,
            DecisionSensitivity.balanced.evaluatorPassThreshold,
            "decisive must lower the pass bar (advance on a softer pass)"
        )
        // Decisive still injects medium+ on answers (it acts MORE via the lower
        // evaluator bar, not by lowering the answer floor below balanced).
        XCTAssertEqual(DecisionSensitivity.decisive.minAnswerConfidenceToInject, .medium)
    }

    func testThresholdsStayInSaneBand() {
        for s in DecisionSensitivity.allCases {
            XCTAssertGreaterThan(s.evaluatorPassThreshold, 0.5, "\(s) bar must not be trivially passable")
            XCTAssertLessThanOrEqual(s.evaluatorPassThreshold, 1.0, "\(s) bar must be a valid score")
        }
    }

    // MARK: - Persistence round-trip (isolated UserDefaults)

    func testStoreRoundTripsThroughIsolatedDefaults() {
        let defaults = isolatedDefaults()

        DecisionSensitivityStore.set(.cautious, defaults: defaults)
        XCTAssertEqual(DecisionSensitivityStore.current(defaults: defaults), .cautious)

        DecisionSensitivityStore.set(.decisive, defaults: defaults)
        XCTAssertEqual(DecisionSensitivityStore.current(defaults: defaults), .decisive)

        DecisionSensitivityStore.set(.balanced, defaults: defaults)
        XCTAssertEqual(DecisionSensitivityStore.current(defaults: defaults), .balanced)
    }

    func testStoreFallsBackToBalancedOnUnknownStoredValue() {
        let defaults = isolatedDefaults()
        defaults.set("nonsense", forKey: DecisionSensitivityStore.defaultsKey)
        XCTAssertEqual(DecisionSensitivityStore.current(defaults: defaults), .balanced,
                       "an unrecognized stored value must degrade to the default, not crash")
    }

    // MARK: - Confidence ordering (the engine's answer-gate primitive)

    func testConfidenceRankOrdering() {
        XCTAssertLessThan(EngineeringAnswer.Confidence.low.rank, EngineeringAnswer.Confidence.medium.rank)
        XCTAssertLessThan(EngineeringAnswer.Confidence.medium.rank, EngineeringAnswer.Confidence.high.rank)
    }

    func testConfidenceMeetsGate() {
        // Balanced gate (.medium): medium+ acts, low escalates.
        XCTAssertTrue(EngineeringAnswer.Confidence.high.meets(.medium))
        XCTAssertTrue(EngineeringAnswer.Confidence.medium.meets(.medium))
        XCTAssertFalse(EngineeringAnswer.Confidence.low.meets(.medium))

        // Cautious gate (.high): only high acts; medium now escalates.
        XCTAssertTrue(EngineeringAnswer.Confidence.high.meets(.high))
        XCTAssertFalse(EngineeringAnswer.Confidence.medium.meets(.high))
        XCTAssertFalse(EngineeringAnswer.Confidence.low.meets(.high))
    }

    /// The exact act-vs-escalate decision the engine makes for an answer, derived
    /// purely from the sensitivity gate. This mirrors the engine's branch
    /// (`answer.confidence.meets(minAnswerConfidenceToInject)`) so the mapping
    /// from setting -> behavior is asserted without a live model call.
    func testAnswerGateBySensitivity() {
        func injects(_ confidence: EngineeringAnswer.Confidence, _ s: DecisionSensitivity) -> Bool {
            confidence.meets(s.minAnswerConfidenceToInject)
        }
        // Balanced: medium injects (today's behavior).
        XCTAssertTrue(injects(.medium, .balanced))
        XCTAssertFalse(injects(.low, .balanced))
        // Cautious: a medium answer now ESCALATES instead of injecting.
        XCTAssertFalse(injects(.medium, .cautious))
        XCTAssertTrue(injects(.high, .cautious))
        // Decisive: still injects medium (acts more overall via the evaluator bar).
        XCTAssertTrue(injects(.medium, .decisive))
    }

    // MARK: - Helpers

    /// A throwaway UserDefaults suite so a round-trip never touches the app's
    /// real `.standard` domain (which the running Supervisor reads).
    private func isolatedDefaults() -> UserDefaults {
        let name = "supervisor.sensitivity.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
}
