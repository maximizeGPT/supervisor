// PrinciplesResolverTests.swift
//
// Pins the stub-rejection contract: a sub-threshold (stub) candidate is
// skipped in favor of a later real-sized one; all-stub yields nil
// (degrade); a real first candidate is accepted. Regression guard for
// the dual-instance incident where a backup bundle's 3.8k-char stub
// PRINCIPLES.md was loaded over the real ~35k file.

import XCTest
@testable import SupervisorCore

final class PrinciplesResolverTests: XCTestCase {

    private let real = String(repeating: "x", count: 35000)   // ~35k, real
    private let stub = String(repeating: "y", count: 3838)    // 3.8k, the known stub size

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/fake/\(name)/PRINCIPLES.md")
    }

    func testStubFirstCandidateSkippedForLaterReal() {
        let stubURL = url("bundle")
        let realURL = url("repo")
        var stubbed: [(URL, Int)] = []

        let resolved = PrinciplesResolver.resolve(
            candidates: [stubURL, realURL],
            read: { $0 == stubURL ? self.stub : self.real },
            onStub: { stubbed.append(($0, $1)) }
        )

        XCTAssertEqual(resolved?.path, realURL)
        XCTAssertEqual(resolved?.text.count, real.count)
        XCTAssertEqual(stubbed.count, 1)
        XCTAssertEqual(stubbed.first?.0, stubURL)
        XCTAssertEqual(stubbed.first?.1, stub.count)
    }

    func testAllStubYieldsNil() {
        let a = url("bundle")
        let b = url("backup")
        var stubbedCount = 0

        let resolved = PrinciplesResolver.resolve(
            candidates: [a, b],
            read: { _ in self.stub },
            onStub: { _, _ in stubbedCount += 1 }
        )

        XCTAssertNil(resolved)
        XCTAssertEqual(stubbedCount, 2)
    }

    func testRealFirstCandidateAccepted() {
        let realURL = url("repo")
        let resolved = PrinciplesResolver.resolve(
            candidates: [realURL, url("other")],
            read: { _ in self.real }
        )
        XCTAssertEqual(resolved?.path, realURL)
    }

    func testMissingAndEmptyCandidatesAreSkipped() {
        let missingURL = url("missing")
        let emptyURL = url("empty")
        let realURL = url("repo")

        let resolved = PrinciplesResolver.resolve(
            candidates: [missingURL, emptyURL, realURL],
            read: { u in
                switch u {
                case missingURL: return nil   // unreadable
                case emptyURL: return ""      // empty
                default: return self.real
                }
            }
        )
        XCTAssertEqual(resolved?.path, realURL)
    }

    func testNoCandidatesYieldsNil() {
        let resolved = PrinciplesResolver.resolve(
            candidates: [],
            read: { _ in self.real }
        )
        XCTAssertNil(resolved)
    }

    func testThresholdBoundaryIsInclusive() {
        // Exactly stubThreshold chars is accepted (the bound is "below").
        let atThreshold = String(repeating: "z", count: PrinciplesResolver.stubThreshold)
        let resolved = PrinciplesResolver.resolve(
            candidates: [url("boundary")],
            read: { _ in atThreshold }
        )
        XCTAssertEqual(resolved?.text.count, PrinciplesResolver.stubThreshold)

        // One char under threshold is rejected.
        let underThreshold = String(repeating: "z", count: PrinciplesResolver.stubThreshold - 1)
        let rejected = PrinciplesResolver.resolve(
            candidates: [url("under")],
            read: { _ in underThreshold }
        )
        XCTAssertNil(rejected)
    }
}
