// StableHashTests.swift — golden pins for the shared FNV-1a stable hash
// (issue #54 item 3: one utility replacing the private ReviewFindingStore /
// MemoryEntry copies, verified byte-for-byte identical before the merge).
//
// The golden hex values were computed OUTSIDE this codebase, in Python, with
// the same algorithm (offset basis 0xcbf29ce484222325, prime 0x100000001b3,
// XOR-then-multiply over UTF-8 bytes, lowercase unpadded hex). They pin the
// on-disk identity contract across the consolidation: review-finding
// fingerprints and second-brain entry ids already persisted were minted with
// exactly this function. If one of these assertions ever fails, fix the code
// — never the expectation — or every stored id/fingerprint is orphaned.

import XCTest
@testable import SupervisorCore

final class StableHashTests: XCTestCase {

    func testGoldenValues() {
        // Empty input = the FNV-1a offset basis, untouched.
        XCTAssertEqual(StableHash.fnv1a64Hex(""), "cbf29ce484222325")
        // The published FNV-1a 64 test vector for "a".
        XCTAssertEqual(StableHash.fnv1a64Hex("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(StableHash.fnv1a64Hex("hello world"), "779a65e7023cd2e7")
        XCTAssertEqual(
            StableHash.fnv1a64Hex("The quick brown fox jumps over the lazy dog"),
            "f3f9b7f5e7e47110"
        )
        // Multi-byte input hashes the UTF-8 BYTES, not scalars.
        XCTAssertEqual(StableHash.fnv1a64Hex("caf\u{E9} \u{2615}"), "1e9db3a4b5c684d4")
    }

    /// The two persisted-id surfaces that switched to the shared hash must
    /// mint the exact same ids their private copies minted.
    func testPersistedIdSurfacesUnchangedByConsolidation() {
        XCTAssertEqual(
            ReviewFindingStore.fingerprint(
                sessionId: "s", filePath: "/f.swift", title: "Off-by-one in the loop"
            ),
            "f9666f1959fc2f36",
            "review-finding fingerprint must survive the consolidation (on-disk dedup)"
        )
        XCTAssertEqual(
            MemoryEntry.makeID(kind: .decision, text: "Use GRDB for storage"),
            "8e4d5436a7b12d00",
            "memory-entry id must survive the consolidation (ledger identity)"
        )
    }
}
