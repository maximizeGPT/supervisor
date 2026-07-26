// TranscriptTailTests.swift — coverage for the shared transcript tail reader
// (issue #54 item 3: one utility replacing the private AsyncWorkScanner /
// MemoryDistiller copies).
//
// The headline regression here is the UTF-8 boundary bug both private copies
// shared: a tail byte-window that opened mid-way through a multi-byte
// character made `String(data:encoding:)` return nil and the WHOLE tail came
// back empty (triage lost recent events; the second brain lost candidates).
// The shared reader now skips the leading continuation bytes, so at worst the
// partial character — which sits on the partial LINE that is dropped anyway —
// is lost. Every byte offset below is computed from the fixture's literal
// UTF-8 layout so the boundary placement is deterministic.

import XCTest
@testable import SupervisorCore

final class TranscriptTailTests: XCTestCase {

    /// Write `text` to a throwaway file, cleaned up at teardown.
    private func writeTempFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-tail-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - UTF-8 boundary regression

    /// Window start landing on each of the emoji's three continuation bytes:
    /// the old copies returned [] (decode nil -> whole tail dropped); the
    /// shared reader must return everything after the partial line.
    ///
    /// Layout ("😀" = F0 9F 98 80, bytes 4-7):
    ///   AAAA😀BBBB\nline-1\nline-2
    ///   0-3 4--7 8-11 12  13-18 19 20-25     size = 26
    func testWindowStartingMidEmojiReturnsTailInsteadOfNothing() throws {
        let content = "AAAA\u{1F600}BBBB\nline-1\nline-2"
        let size = content.utf8.count
        XCTAssertEqual(size, 26, "fixture layout drifted — offsets below assume this exact byte count")
        let url = try writeTempFile(content)

        for start in 5...7 {  // the emoji's continuation bytes
            let lines = TranscriptTail.readTailLines(url, tailBytes: size - start)
            XCTAssertNotNil(lines)
            // The old failure shape: mid-sequence decode failed and EVERYTHING
            // in the window was dropped. Non-empty proves the decode succeeded.
            XCTAssertFalse(lines?.isEmpty ?? true, "start=\(start): tail must not vanish on a mid-character cut")
            XCTAssertEqual(lines, ["line-1", "line-2"], "start=\(start)")
        }
    }

    /// Window start landing exactly ON the emoji's lead byte: no continuation
    /// skip needed, and the drop-first-partial-LINE behavior still applies.
    func testWindowStartAtSequenceLeadByteKeepsPartialLineDrop() throws {
        let content = "AAAA\u{1F600}BBBB\nline-1\nline-2"
        let size = content.utf8.count
        let url = try writeTempFile(content)

        let lines = TranscriptTail.readTailLines(url, tailBytes: size - 4)
        XCTAssertEqual(lines, ["line-1", "line-2"])
    }

    /// Same regression with a 2-byte character ("é" = C3 A9, bytes 1-2):
    ///   aébc\nlast
    ///   0 1-2 3 4 5 6-9     size = 10, start = 2 cuts mid-é.
    func testWindowStartingMidTwoByteCharReturnsTail() throws {
        let content = "a\u{E9}bc\nlast"
        let size = content.utf8.count
        XCTAssertEqual(size, 10, "fixture layout drifted — offsets assume this exact byte count")
        let url = try writeTempFile(content)

        let lines = TranscriptTail.readTailLines(url, tailBytes: size - 2)
        XCTAssertEqual(lines, ["last"])
    }

    // MARK: - Equivalence with the pre-consolidation behavior

    /// A window covering the whole file (no cut): every line, nothing dropped
    /// — identical to both old private copies.
    func testWholeFileWindowReturnsAllLines() throws {
        let url = try writeTempFile("line-1\nline-2\nline-3")
        XCTAssertEqual(
            TranscriptTail.readTailLines(url, tailBytes: 1024 * 1024),
            ["line-1", "line-2", "line-3"]
        )
    }

    /// Trailing newline yields a trailing empty element (components(separatedBy:)
    /// semantics) — pre-existing behavior both callers already tolerate.
    func testTrailingNewlineKeepsEmptyLastElement() throws {
        let url = try writeTempFile("a\nb\n")
        XCTAssertEqual(TranscriptTail.readTailLines(url, tailBytes: 1024), ["a", "b", ""])
    }

    func testEmptyFileReturnsEmptyArray() throws {
        let url = try writeTempFile("")
        XCTAssertEqual(TranscriptTail.readTailLines(url, tailBytes: 1024), [])
    }

    func testMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-tail-missing-\(UUID().uuidString).jsonl")
        XCTAssertNil(TranscriptTail.readTailLines(url, tailBytes: 1024))
    }

    /// An ASCII mid-line cut drops ONLY the leading partial line — the
    /// behavior both old copies had, preserved on top of the UTF-8 fix.
    ///
    ///   line-1\nline-2\nline-3
    ///   0-5    6  7-12  13  14-19     size = 20, start = 9 cuts inside line-2.
    func testAsciiMidLineCutDropsOnlyThePartialLine() throws {
        let content = "line-1\nline-2\nline-3"
        let size = content.utf8.count
        XCTAssertEqual(size, 20, "fixture layout drifted — offsets assume this exact byte count")
        let url = try writeTempFile(content)

        let lines = TranscriptTail.readTailLines(url, tailBytes: size - 9)
        XCTAssertEqual(lines, ["line-3"])
    }
}
