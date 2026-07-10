// EventParserFileEditTests.swift
//
// v0.3.x REVIEW dimension — the parser now emits `.fileEdit` for the
// file-writing tools (Edit / Write / MultiEdit) that the REVIEW dimension
// reviews, while Bash still emits `.bashToolCall` unchanged and other tools
// (Read/Grep/…) still emit nothing.

import XCTest
@testable import SupervisorCore

final class EventParserFileEditTests: XCTestCase {

    private func parser() -> EventParser {
        EventParser(projectHash: "-Users-test", jsonlPath: "/tmp/test.jsonl")
    }

    private func fileEdits(_ events: [SupervisorEvent]) -> [FileEditInfo] {
        events.compactMap { if case .fileEdit(let v) = $0 { return v }; return nil }
    }

    // MARK: - Edit

    func testEditEmitsFileEditWithOneHunk() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22.000Z","sessionId":"s","uuid":"asst-1","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_edit","name":"Edit","input":{"file_path":"/Users/test/A.swift","old_string":"let x = 1","new_string":"let x = 2"}}]}}
        """#
        let edits = fileEdits(parser().parse(line: line))
        guard let e = edits.first else { return XCTFail("expected one fileEdit, got \(edits.count)") }
        XCTAssertEqual(e.toolName, "Edit")
        XCTAssertEqual(e.filePath, "/Users/test/A.swift")
        XCTAssertEqual(e.toolUseId, "toolu_edit")
        XCTAssertEqual(e.turnUUID, "asst-1")
        XCTAssertEqual(e.hunks.count, 1)
        XCTAssertEqual(e.hunks.first?.oldString, "let x = 1")
        XCTAssertEqual(e.hunks.first?.newString, "let x = 2")
    }

    // MARK: - Write

    func testWriteEmitsFileEditWithNilOldString() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22.000Z","sessionId":"s","uuid":"asst-2","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_write","name":"Write","input":{"file_path":"/Users/test/New.swift","content":"import Foundation\nlet y = 3"}}]}}
        """#
        let edits = fileEdits(parser().parse(line: line))
        guard let e = edits.first else { return XCTFail("expected one fileEdit") }
        XCTAssertEqual(e.toolName, "Write")
        XCTAssertEqual(e.filePath, "/Users/test/New.swift")
        XCTAssertEqual(e.hunks.count, 1)
        XCTAssertNil(e.hunks.first?.oldString, "Write has no prior text")
        XCTAssertEqual(e.hunks.first?.newString, "import Foundation\nlet y = 3")
    }

    // MARK: - MultiEdit

    func testMultiEditEmitsOneHunkPerEdit() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22.000Z","sessionId":"s","uuid":"asst-3","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_multi","name":"MultiEdit","input":{"file_path":"/Users/test/M.swift","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}}]}}
        """#
        let edits = fileEdits(parser().parse(line: line))
        guard let e = edits.first else { return XCTFail("expected one fileEdit") }
        XCTAssertEqual(e.toolName, "MultiEdit")
        XCTAssertEqual(e.hunks.count, 2)
        XCTAssertEqual(e.hunks[0].oldString, "a")
        XCTAssertEqual(e.hunks[0].newString, "b")
        XCTAssertEqual(e.hunks[1].oldString, "c")
        XCTAssertEqual(e.hunks[1].newString, "d")
    }

    // MARK: - Non-reviewable tools still emit nothing

    func testReadToolEmitsNoFileEdit() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22.000Z","sessionId":"s","uuid":"asst-4","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"/Users/test/A.swift"}}]}}
        """#
        XCTAssertTrue(fileEdits(parser().parse(line: line)).isEmpty, "Read is not a fileEdit")
    }

    func testWriteWithoutContentEmitsNothing() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22.000Z","sessionId":"s","uuid":"asst-5","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_w2","name":"Write","input":{"file_path":"/Users/test/A.swift"}}]}}
        """#
        XCTAssertTrue(fileEdits(parser().parse(line: line)).isEmpty, "a Write with no content is not reviewable")
    }

    // MARK: - Bash is unaffected

    func testBashStillEmitsBashToolCallNotFileEdit() {
        let line = #"""
        {"type":"assistant","timestamp":"2026-05-21T19:36:22.000Z","sessionId":"s","uuid":"asst-6","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_bash","name":"Bash","input":{"command":"ls -la","description":"list"}}]}}
        """#
        let events = parser().parse(line: line)
        XCTAssertTrue(fileEdits(events).isEmpty, "Bash must not become a fileEdit")
        let bash = events.compactMap { if case .bashToolCall(let v) = $0 { return v }; return nil }
        XCTAssertEqual(bash.first?.command, "ls -la", "the existing Bash path is unchanged")
    }

    // MARK: - Truncation guard

    func testHugeWriteContentIsTruncated() {
        let huge = String(repeating: "z", count: EventParser.fileEditHunkCap + 5_000)
        // Build the JSON safely (the content is huge) via JSONSerialization.
        let obj: [String: Any] = [
            "type": "assistant", "timestamp": "2026-05-21T19:36:22.000Z",
            "sessionId": "s", "uuid": "asst-7",
            "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": "toolu_big", "name": "Write",
                "input": ["file_path": "/Users/test/Big.swift", "content": huge] as [String: Any],
            ]]],
        ]
        let line = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        let edits = fileEdits(parser().parse(line: line))
        let newString = try! XCTUnwrap(edits.first?.hunks.first?.newString)
        XCTAssertLessThan(newString.utf8.count, EventParser.fileEditHunkCap + 100, "content is capped")
        XCTAssertTrue(newString.hasSuffix("…[truncated]"), "truncation is marked")
    }
}
