// FixtureCorpusShapeTests.swift — corpus-shape ratchet for the
// calibration fixtures.
//
// The calibration sweeps (RubricCalibrationTests) interpret their pass
// rates against a corpus of a KNOWN size and composition — "40/40
// negatives passed" only means something if there really are 40
// negatives. These tests pin the exact per-file, per-kind counts so any
// silent drift (a fixture deleted in a refactor, a `kind:` typo'd, a
// file dropped from `FixtureCorpus.all`) fails loudly instead of
// quietly skewing calibration numbers.
//
// RATCHET: these numbers are intentionally hardcoded. If you
// INTENTIONALLY add, remove, or re-kind fixtures, update the expected
// counts here in the same PR (and the fixture file's header comment) —
// that forces corpus changes to be visible in review. Runs fully
// offline; no API.

import XCTest

final class FixtureCorpusShapeTests: XCTestCase {

    /// Per-kind tally of a fixture list.
    private func tally(_ kinds: [FixtureKind]) -> (positive: Int, negative: Int, adversarial: Int) {
        (
            positive: kinds.filter { $0 == .clearPositive }.count,
            negative: kinds.filter { $0 == .clearNegative }.count,
            adversarial: kinds.filter { $0 == .adversarial }.count
        )
    }

    private func assertShape(
        _ fixtures: [CalibrationFixture], named fixtureFile: String,
        positive: Int, negative: Int, adversarial: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let t = tally(fixtures.map(\.kind))
        XCTAssertEqual(t.positive, positive,
                       "\(fixtureFile): clearPositive count drifted", file: file, line: line)
        XCTAssertEqual(t.negative, negative,
                       "\(fixtureFile): clearNegative count drifted", file: file, line: line)
        XCTAssertEqual(t.adversarial, adversarial,
                       "\(fixtureFile): adversarial count drifted", file: file, line: line)
        XCTAssertEqual(fixtures.count, positive + negative + adversarial,
                       "\(fixtureFile): total count drifted", file: file, line: line)
    }

    // MARK: - Per-file shape

    func testDestructiveFixturesShape() {
        // 102 = 42 clearPositive + 40 clearNegative + 20 adversarial.
        // (Two positives beyond the original 40-per-kind spec were added
        // deliberately; see the file's header.)
        assertShape(DestructiveFixtures.fixtures, named: "DestructiveFixtures",
                    positive: 42, negative: 40, adversarial: 20)
    }

    func testEditsFixturesShape() {
        // 100 = 40 clearPositive + 39 clearNegative + 21 adversarial.
        // (edits.adv.021 was deliberately re-kinded from clearNegative to
        // adversarial; see the inline note next to it in EditsFixtures.)
        assertShape(EditsFixtures.fixtures, named: "EditsFixtures",
                    positive: 40, negative: 39, adversarial: 21)
    }

    func testInjectionFixturesShape() {
        // 100 = 40 clearPositive + 40 clearNegative + 20 adversarial.
        assertShape(InjectionFixtures.fixtures, named: "InjectionFixtures",
                    positive: 40, negative: 40, adversarial: 20)
    }

    func testQuestionFixturesShape() {
        // 90 = 45 clearPositive + 45 clearNegative (no adversarial):
        // 15 positives + 15 negatives for each question_type.
        let fixtures = QuestionFixtures.fixtures
        let t = tally(fixtures.map(\.kind))
        XCTAssertEqual(t.positive, 45, "QuestionFixtures: clearPositive count drifted")
        XCTAssertEqual(t.negative, 45, "QuestionFixtures: clearNegative count drifted")
        XCTAssertEqual(t.adversarial, 0, "QuestionFixtures: corpus has no adversarial fixtures")
        XCTAssertEqual(fixtures.count, 90, "QuestionFixtures: total count drifted")

        // Positives split evenly across the three question types.
        for type in ["engineering", "safety", "taste"] {
            let n = fixtures.filter { $0.expectedQuestionType == type }.count
            XCTAssertEqual(n, 15, "QuestionFixtures: \(type) positive count drifted")
        }
        // Negatives never carry an expected type.
        XCTAssertTrue(
            fixtures.filter { $0.kind == .clearNegative }.allSatisfy { $0.expectedQuestionType == nil },
            "QuestionFixtures: clearNegative fixtures must not set expectedQuestionType")
    }

    // MARK: - Combined corpus

    func testFixtureCorpusAllIsTheThreeCommandCorpora() {
        // FixtureCorpus.all drives testCalibrateFullCorpus. It is the three
        // command-triage corpora (destructive + edits + injection); the
        // question corpus has its own sweep and is intentionally excluded.
        XCTAssertEqual(FixtureCorpus.all.count, 302,
                       "FixtureCorpus.all drifted from 102 + 100 + 100")
        XCTAssertEqual(FixtureCorpus.all.count,
                       DestructiveFixtures.fixtures.count
                           + EditsFixtures.fixtures.count
                           + InjectionFixtures.fixtures.count,
                       "FixtureCorpus.all must be exactly the three per-category files combined")

        let t = tally(FixtureCorpus.all.map(\.kind))
        XCTAssertEqual(t.positive, 122, "combined clearPositive count drifted (42+40+40)")
        XCTAssertEqual(t.negative, 119, "combined clearNegative count drifted (40+39+40)")
        XCTAssertEqual(t.adversarial, 61, "combined adversarial count drifted (20+21+20)")
    }

    func testFixtureNamesAreUnique() {
        // Duplicate names would make calibration reports ambiguous and can
        // hide a copy-paste of an existing fixture instead of a new one.
        var seen = Set<String>()
        for f in FixtureCorpus.all {
            XCTAssertTrue(seen.insert(f.name).inserted, "duplicate fixture name: \(f.name)")
        }
        var seenQ = Set<String>()
        for f in QuestionFixtures.fixtures {
            XCTAssertTrue(seenQ.insert(f.name).inserted, "duplicate question fixture name: \(f.name)")
        }
    }
}
