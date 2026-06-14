import XCTest
@testable import SupervisorCore

/// The dispatcher anchors on the session objective — its opening user prompt —
/// to drive toward what the user asked for. These lock the JSONL read: first
/// plain user prompt wins, tool_result user messages are skipped, missing/empty
/// transcripts return nil (caller falls back to local reasoning).
final class SessionObjectiveTests: XCTestCase {

    /// Temp projects dir with one project subdir holding <sid>.jsonl, matching
    /// DesktopConversationTargeter.transcriptURL's lookup shape.
    private func makeTranscript(sid: String, lines: [String]) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("objtest-\(UUID().uuidString)", isDirectory: true)
        let proj = base.appendingPathComponent("project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: proj.appendingPathComponent("\(sid).jsonl"), atomically: true, encoding: .utf8)
        return base
    }

    func testReadsFirstPlainUserPromptAsObjective() throws {
        let sid = "obj-basic"
        let base = try makeTranscript(sid: sid, lines: [
            #"{"type":"user","message":{"role":"user","content":"Build a tweet engine that posts to X"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(SessionObjective.read(sessionId: sid, projectsDir: base),
                       "Build a tweet engine that posts to X")
    }

    func testSkipsToolResultUserMessages() throws {
        // A user message whose content is an ARRAY (tool_result) is not the
        // objective; the first STRING-content user message is.
        let sid = "obj-skip"
        let base = try makeTranscript(sid: sid, lines: [
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"output"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"The real objective"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(SessionObjective.read(sessionId: sid, projectsDir: base), "The real objective")
    }

    func testNilWhenNoPlainUserPrompt() throws {
        let sid = "obj-none"
        let base = try makeTranscript(sid: sid, lines: [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNil(SessionObjective.read(sessionId: sid, projectsDir: base))
    }

    func testNilWhenTranscriptMissing() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(SessionObjective.read(sessionId: "any", projectsDir: empty))
    }
}
