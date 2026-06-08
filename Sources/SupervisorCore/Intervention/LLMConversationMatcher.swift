// LLMConversationMatcher — Path B (text) semantic matcher for desktop
// conversation targeting.
//
// The local token-overlap matcher (DesktopConversationTargeter.bestMatch)
// can't reliably match the OCR'd sidebar text against the JSONL ai-title,
// because the desktop app TRUNCATES and REWORDS titles. A live failure from
// 2026-06-08T18:07:
//
//     target  = "Ship pause and kill interventions for Supervisor v0.1.2"
//     sidebar = "Pause and kill interventions"   (truncated)
//     local score = 0.50  ->  below the 0.6 gate  ->  degraded, no inject
//
// And the active title can be a full rewording of the same conversation
// ("Sign, notarize, and package Supervisor macOS apps" vs the desktop's
// "Supervisor macOS app signing and notarization"). Token math rates these
// low; a model reading them calls them the same conversation immediately.
//
// This matcher hands the target + the sidebar candidates to the user's
// configured provider (Path B uses the active text provider, e.g. deepseek,
// on the OCR'd text — no vision model required) and asks which entry is the
// SAME conversation, with a confidence the targeter then gates on. The prompt
// biases hard toward LOW confidence when unsure: a wrong-conversation inject
// is the failure we must never produce (confident-match-or-notify), so an
// uncertain match degrades to notify rather than clicking and guessing.
//
// It runs SYNCHRONOUSLY (blocks on a semaphore) so it slots straight into the
// targeter's sync `matcher` closure. The caller is the dedicated
// desktop-targeting serial queue, off the @MainActor — already built to block
// for the ~4s targeting pass — so a blocking LLM call here never touches the
// main thread or the cooperative pool the triage/catch engine runs on. On any
// failure (timeout, no response, unparseable) it returns nil so the caller
// falls back to the local matcher rather than losing targeting entirely.

import Foundation

public struct LLMConversationMatcher: Sendable {

    private let client: LLMClient
    private let trace: TraceLog
    private let timeout: TimeInterval

    public init(client: LLMClient, trace: TraceLog = .shared, timeout: TimeInterval = 8) {
        self.client = client
        self.trace = trace
        self.timeout = timeout
    }

    /// Sync entry point shaped for `DesktopConversationTargeter.focusConversation`'s
    /// `matcher` closure. Returns the chosen candidate + confidence (0-1), or
    /// nil ONLY on LLM failure so the caller can fall back to the local matcher.
    /// A parsed-but-low-confidence result is returned as-is and gated by the
    /// targeter's `confidenceThreshold`.
    public func match(
        target: String,
        candidates: [DesktopConversationCandidate]
    ) -> (DesktopConversationCandidate, Double)? {
        guard !candidates.isEmpty else { return nil }

        let req = Self.request(
            target: target,
            candidates: candidates,
            model: client.provider.defaultTriageModel
        )

        // Block this (off-main, dedicated-queue) thread on the async call.
        final class Box: @unchecked Sendable { var resp: AnthropicMessageResponse? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let client = self.client
        Task.detached {
            box.resp = try? await client.createMessage(req)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            trace.emit("desktop", "llm_match timeout=\(Int(timeout))s -> local fallback")
            return nil
        }

        guard let resp = box.resp,
              let (idx, conf) = Self.parse(resp),
              idx >= 0, idx < candidates.count
        else {
            trace.emit("desktop", "llm_match no_parse -> local fallback")
            return nil
        }

        let chosen = candidates[idx]
        trace.emit("desktop", "llm_match idx=\(idx) conf=\(String(format: "%.2f", conf)) title=\"\(chosen.text.prefix(60))\"")
        return (chosen, conf)
    }

    // MARK: - Request

    static let toolName = "record_match"

    static func request(
        target: String,
        candidates: [DesktopConversationCandidate],
        model: String
    ) -> AnthropicMessageRequest {
        var list = ""
        for (i, c) in candidates.enumerated() {
            list += "\(i): \"\(c.text)\"\n"
        }
        let user = """
        # Target conversation title (from the session's own metadata)
        "\(target)"

        # Sidebar entries (the chat app's conversation list, OCR'd off screen — \
        often truncated or reworded versions of the real titles)
        \(list)
        # Task
        Identify the ONE sidebar entry that is the SAME conversation as the \
        target. Judge by meaning, not exact characters: the sidebar text is \
        frequently a truncated or reworded form of the target. If no entry is \
        clearly the same conversation, return your closest guess with LOW \
        confidence so the caller does not switch. Call record_match exactly once.
        """
        return AnthropicMessageRequest(
            model: model,
            max_tokens: 80,
            system: systemPrompt,
            messages: [.init(role: "user", content: .string(user))],
            tools: [matchTool],
            tool_choice: .forced(toolName)
        )
    }

    static let systemPrompt = """
    You match a target conversation title against a chat app's sidebar list. \
    The sidebar entries are OCR'd off the screen and are frequently truncated \
    or reworded versions of the real title. Decide which entry refers to the \
    SAME conversation as the target, judging by meaning rather than exact \
    characters.

    Your answer gates a click that switches the user's ACTIVE conversation, so \
    a wrong pick sends an answer into the wrong chat. Be conservative:
      - 0.9-1.0: you are confident this entry is the same conversation (a clear \
        semantic match, even if truncated or reworded).
      - 0.6-0.8: probable match with minor ambiguity.
      - below 0.6: no entry is clearly the same conversation. Prefer this and \
        let the caller decline rather than guessing wrong.
    Return the 0-based index of your best candidate and a confidence from 0 to 1.
    """

    static var matchTool: AnthropicTool {
        AnthropicTool(
            name: toolName,
            description: "Record which sidebar entry is the same conversation as the target.",
            input_schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "index": .object([
                        "type": .string("integer"),
                        "description": .string("0-based index of the best-matching sidebar entry.")
                    ]),
                    "confidence": .object([
                        "type": .string("number"),
                        "description": .string("0 to 1. 0.9+ means sure it is the same conversation; below 0.6 means no clear match, do not switch.")
                    ])
                ]),
                "required": .array([.string("index"), .string("confidence")])
            ])
        )
    }

    // MARK: - Parse

    /// Pull (index, confidence) out of the forced tool call. Accepts the number
    /// fields as integer, double, OR numeric string — OpenAI-compatible
    /// providers (deepseek et al.) encode tool arguments inconsistently.
    static func parse(_ response: AnthropicMessageResponse) -> (Int, Double)? {
        for block in response.content {
            guard block.type == "tool_use",
                  block.name == toolName,
                  case let .object(input)? = block.input
            else { continue }

            guard let idx = intValue(input["index"]),
                  let confRaw = doubleValue(input["confidence"])
            else { return nil }

            return (idx, max(0, min(1, confRaw)))
        }
        return nil
    }

    static func intValue(_ v: AnthropicJSON?) -> Int? {
        switch v {
        case .integer(let n)?: return Int(n)
        case .double(let d)?: return Int(d)
        case .string(let s)?: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    static func doubleValue(_ v: AnthropicJSON?) -> Double? {
        switch v {
        case .double(let d)?: return d
        case .integer(let n)?: return Double(n)
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
