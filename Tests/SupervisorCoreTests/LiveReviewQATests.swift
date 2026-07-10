// LiveReviewQATests.swift
//
// LIVE quality harness for the REVIEW dimension. Unlike the mocked-LLM unit
// tests, this drives the real ReviewEngine against a real provider (DeepSeek by
// default) over a battery of realistic code-change scenarios — some with genuine
// bugs that SHOULD be flagged, some clean / style-only that should stay SILENT —
// and writes a structured report the QA loop's evaluator agents grade.
//
// It is SKIPPED unless a key is provided, so CI (which has none) stays green:
//   - REVIEW_QA_KEYFILE  path to a file containing the API key (preferred), or
//   - DEEPSEEK_API_KEY / <PROVIDER>_API_KEY  the key directly in the env.
// Optional:
//   - REVIEW_QA_PROVIDER    provider raw value (default "deepseek")
//   - REVIEW_QA_SCENARIOS   path to a JSON array of scenarios (overrides the
//                           built-in battery, so the planner agent can expand it)
//   - REVIEW_QA_OUT         path to write the results JSON (default: a temp file,
//                           whose path is printed)
//   - REVIEW_QA_SENSITIVITY cautious | balanced | decisive (default balanced)
//
// The key is NEVER logged or written anywhere by this harness.

import XCTest
import GRDB
@testable import SupervisorCore

@MainActor
final class LiveReviewQATests: XCTestCase {

    // MARK: - Scenario / result models (JSON-shaped for the agent loop)

    struct QAHunk: Codable { let old: String?; let new: String }

    struct QAScenario: Codable {
        let id: String
        let description: String
        let objective: String
        var reasoning: String? = nil
        var priorContext: [String]? = nil
        let filePath: String
        // Optional so agent-authored JSON may omit it (synthesized Decodable
        // ignores default values for non-optional properties). Defaults to "Edit"
        // at use. Also tolerate a hint key the model may emit.
        var toolName: String? = nil
        let hunks: [QAHunk]
        let expectShouldFlag: Bool
        var expectCategory: String? = nil
    }

    struct QAFinding: Codable {
        let category, severity, confidence, filePath, title, detail: String
        let surfaced: Bool
    }

    struct QAResult: Codable {
        let id, description, objective: String
        let expectShouldFlag: Bool
        let expectCategory: String?
        let surfacedCount: Int
        let correctFlagDecision: Bool
        let findings: [QAFinding]
        let latencyMs: Int
        let inputTokens: Int
        let outputTokens: Int
    }

    struct QAReport: Codable {
        let provider: String
        let model: String
        let sensitivity: String
        let total: Int
        let correctFlagDecisions: Int
        let flagDecisionAccuracy: Double
        let falseNegatives: [String]   // should-flag scenarios that stayed silent
        let falsePositives: [String]   // should-be-silent scenarios that flagged
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let results: [QAResult]
    }

    // MARK: - Key + config

    private func loadKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let path = env["REVIEW_QA_KEYFILE"],
           let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty { return k }
        }
        for name in ["DEEPSEEK_API_KEY", "REVIEW_QA_KEY", "ANTHROPIC_API_KEY"] {
            if let k = env[name], !k.isEmpty { return k }
        }
        return nil
    }

    private var provider: LLMProvider {
        let raw = ProcessInfo.processInfo.environment["REVIEW_QA_PROVIDER"] ?? "deepseek"
        return LLMProvider(rawValue: raw) ?? .deepseek
    }

    private var sensitivity: DecisionSensitivity {
        let raw = ProcessInfo.processInfo.environment["REVIEW_QA_SENSITIVITY"] ?? "balanced"
        return DecisionSensitivity(rawValue: raw) ?? .balanced
    }

    private func loadScenarios() -> [QAScenario] {
        if let path = ProcessInfo.processInfo.environment["REVIEW_QA_SCENARIOS"],
           let data = FileManager.default.contents(atPath: path),
           let scenarios = try? JSONDecoder().decode([QAScenario].self, from: data),
           !scenarios.isEmpty {
            return scenarios
        }
        return Self.defaultBattery
    }

    // MARK: - The live run

    func testLiveReviewQABattery() async throws {
        guard let key = loadKey() else {
            throw XCTSkip("no API key (set REVIEW_QA_KEYFILE or DEEPSEEK_API_KEY) — live QA skipped")
        }
        let scenarios = loadScenarios()
        let prov = provider
        let model = prov.defaultTriageModel
        let sens = sensitivity

        // Real token accounting via the client's cost hook.
        let tokenBox = TokenBox()
        let client = LLMClient(
            provider: prov, apiKey: key,
            redactor: DefaultRedactor(),
            traceLog: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("live-qa-client-\(UUID().uuidString).log")),
            costRecorder: { _, usage in tokenBox.add(usage.input_tokens, usage.output_tokens) })

        var results: [QAResult] = []
        for s in scenarios {
            let before = tokenBox.snapshot()
            let (findings, surfaced, ms) = try await runScenario(s, client: client, model: model, sens: sens)
            let after = tokenBox.snapshot()
            let correct = (surfaced > 0) == s.expectShouldFlag
            results.append(QAResult(
                id: s.id, description: s.description, objective: s.objective,
                expectShouldFlag: s.expectShouldFlag, expectCategory: s.expectCategory,
                surfacedCount: surfaced, correctFlagDecision: correct,
                findings: findings, latencyMs: ms,
                inputTokens: after.0 - before.0, outputTokens: after.1 - before.1))
            let mark = correct ? "OK " : "XX "
            print("[live-qa] \(mark)\(s.id) expect=\(s.expectShouldFlag ? "FLAG" : "silent") surfaced=\(surfaced) \(ms)ms — \(s.description)")
            if surfaced > 0, let f = findings.first(where: { $0.surfaced }) {
                print("           ↳ [\(f.severity)/\(f.confidence)] \(f.title)")
            }
        }

        let correctCount = results.filter { $0.correctFlagDecision }.count
        let report = QAReport(
            provider: prov.rawValue, model: model, sensitivity: sens.rawValue,
            total: results.count, correctFlagDecisions: correctCount,
            flagDecisionAccuracy: results.isEmpty ? 0 : Double(correctCount) / Double(results.count),
            falseNegatives: results.filter { $0.expectShouldFlag && $0.surfacedCount == 0 }.map { $0.id },
            falsePositives: results.filter { !$0.expectShouldFlag && $0.surfacedCount > 0 }.map { $0.id },
            totalInputTokens: tokenBox.snapshot().0, totalOutputTokens: tokenBox.snapshot().1,
            results: results)

        // Write the report for the evaluator agents.
        let outPath = ProcessInfo.processInfo.environment["REVIEW_QA_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("live-review-qa-report.json").path
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: URL(fileURLWithPath: outPath))
        print("[live-qa] ===== \(correctCount)/\(results.count) correct flag-decisions (\(Int(report.flagDecisionAccuracy*100))%) | in=\(report.totalInputTokens) out=\(report.totalOutputTokens) tok")
        print("[live-qa] false negatives (missed bugs): \(report.falseNegatives)")
        print("[live-qa] false positives (noise): \(report.falsePositives)")
        print("[live-qa] report written to: \(outPath)")

        // Sanity floor: the live path must actually function (tool-calling +
        // parsing produced at least one finding on the buggy scenarios). Quality
        // grading is the evaluator agents' job, not a brittle assertion here.
        XCTAssertGreaterThan(results.reduce(0) { $0 + $1.surfacedCount }, 0,
            "the live model produced NO findings on any scenario — the live path is broken")
    }

    // MARK: - One scenario through the real engine

    private func runScenario(_ s: QAScenario, client: LLMClient, model: String, sens: DecisionSensitivity)
        async throws -> (findings: [QAFinding], surfaced: Int, latencyMs: Int) {
        let db = try SupervisorDatabase.inMemory()
        try SessionStore(database: db).upsert(StoredSession(
            id: "qa", projectHash: "-qa", cwd: "/proj",
            startedAt: Date(), lastSeenAt: Date(), jsonlPath: "/x"))
        let reviewStore = ReviewFindingStore(database: db)
        let engine = ReviewEngine(
            client: client, bus: EventBus(trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("live-qa-bus-\(UUID().uuidString).log"))),
            model: model, reviewStore: reviewStore, auditStore: AuditStore(database: db),
            debounceInterval: 0.01, minReviewInterval: 0, maxBufferAge: 100,
            enabledOverride: true, sensitivity: { sens },
            trace: TraceLog(path: FileManager.default.temporaryDirectory
                .appendingPathComponent("live-qa-eng-\(UUID().uuidString).log")))

        let turn = "turn-\(s.id)"
        engine.consume(event: .sessionStart(.init(sessionId: "qa", cwd: "/proj", gitBranch: "main", projectHash: "-qa", jsonlPath: "/x", ts: Date())))
        engine.consume(event: .userPrompt(.init(sessionId: "qa", text: s.objective, ts: Date())))
        if let r = s.reasoning, !r.isEmpty {
            engine.consume(event: .assistantText(.init(sessionId: "qa", text: r, turnUUID: turn, ts: Date())))
        }
        let hunks = s.hunks.map { FileEditHunk(oldString: $0.old, newString: $0.new) }
        engine.consume(event: .fileEdit(.init(sessionId: "qa", toolName: s.toolName ?? "Edit", filePath: s.filePath,
                                              hunks: hunks, toolUseId: "tu-\(s.id)", turnUUID: turn, ts: Date())))

        let start = Date()
        await engine.runReview(sessionId: "qa")
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        let rows = (try? reviewStore.recent(sessionId: "qa", limit: 50, surfacedOnly: false)) ?? []
        let findings = rows.map {
            QAFinding(category: $0.category, severity: $0.severity.rawValue, confidence: $0.confidence,
                      filePath: $0.filePath, title: $0.title, detail: $0.detail, surfaced: $0.surfaced)
        }
        return (findings, findings.filter { $0.surfaced }.count, ms)
    }

    // MARK: - Default battery (also the CI-visible spec of what "good" means)

    static let defaultBattery: [QAScenario] = [
        QAScenario(id: "empty-array-force-unwrap",
            description: "Force-unwraps first() on a list that can be empty",
            objective: "Return the cheapest item from the cart.",
            reasoning: "Grabbing the first after sorting by price.",
            filePath: "/proj/Cart.swift",
            hunks: [.init(old: "func cheapest(_ items: [Item]) -> Item {\n  items.sorted { $0.price < $1.price }[0]\n}",
                          new: "func cheapest(_ items: [Item]) -> Item {\n  items.sorted { $0.price < $1.price }.first!\n}")],
            expectShouldFlag: true, expectCategory: "missed_edge_case"),

        QAScenario(id: "off-by-one-loop",
            description: "Loop bound uses <= and reads one past the end",
            objective: "Sum the first n elements.",
            filePath: "/proj/sum.js",
            hunks: [.init(old: "for (let i = 0; i < n; i++) total += a[i];",
                          new: "for (let i = 0; i <= n; i++) total += a[i];")],
            expectShouldFlag: true, expectCategory: "missed_edge_case"),

        QAScenario(id: "sql-injection",
            description: "Builds a SQL query by string interpolation of user input",
            objective: "Add a lookup endpoint that finds a user by name.",
            filePath: "/proj/db.py",
            hunks: [.init(old: "cur.execute('SELECT * FROM users WHERE name = %s', (name,))",
                          new: "cur.execute(f\"SELECT * FROM users WHERE name = '{name}'\")")],
            expectShouldFlag: true, expectCategory: "security_risk"),

        QAScenario(id: "unhandled-nil-body",
            description: "Dereferences req.body without checking it exists",
            objective: "Add POST /submit returning the posted id.",
            filePath: "/proj/server.js",
            hunks: [.init(old: "app.listen(3000)",
                          new: "app.post('/submit', (req, res) => res.json({ id: req.body.id }));\napp.listen(3000)")],
            expectShouldFlag: true, expectCategory: "missed_edge_case"),

        QAScenario(id: "contradicts-utc-decision",
            description: "Uses local time although the objective mandates UTC",
            objective: "Per our logging standard ALL timestamps must be UTC. Add a timestamp to each log line.",
            reasoning: "Adding the current time to the log line.",
            filePath: "/proj/log.go",
            hunks: [.init(old: "line := msg",
                          new: "line := time.Now().Format(\"15:04:05\") + \" \" + msg")],
            expectShouldFlag: true, expectCategory: "contradicts_earlier_decision"),

        QAScenario(id: "division-by-zero",
            description: "Computes an average without guarding an empty count",
            objective: "Add an average() helper.",
            filePath: "/proj/stats.rb",
            hunks: [.init(old: "def average(xs)\n  # todo\nend",
                          new: "def average(xs)\n  xs.sum / xs.length\nend")],
            expectShouldFlag: true, expectCategory: "missed_edge_case"),

        QAScenario(id: "wrong-env-assumption",
            description: "Assumes an env var is always set and non-empty",
            objective: "Read the port from the environment.",
            filePath: "/proj/config.js",
            hunks: [.init(old: "const port = 3000;",
                          new: "const port = parseInt(process.env.PORT);")],
            expectShouldFlag: true, expectCategory: "incorrect_assumption"),

        QAScenario(id: "resource-leak",
            description: "Opens a file handle that is never closed on the error path",
            objective: "Read the config file and parse it.",
            filePath: "/proj/reader.py",
            hunks: [.init(old: "with open(path) as f:\n    return json.load(f)",
                          new: "f = open(path)\nreturn json.load(f)")],
            expectShouldFlag: true, expectCategory: "overlooked_detail"),

        // ---- Should stay SILENT: correct or purely stylistic changes ----

        QAScenario(id: "clean-guarded-first",
            description: "A correct, fully-guarded change — no issue",
            objective: "Return the cheapest item, or nil if the cart is empty.",
            filePath: "/proj/Cart.swift",
            hunks: [.init(old: "func cheapest(_ items: [Item]) -> Item? {\n  // todo\n}",
                          new: "func cheapest(_ items: [Item]) -> Item? {\n  items.sorted { $0.price < $1.price }.first\n}")],
            expectShouldFlag: false),

        QAScenario(id: "pure-rename",
            description: "A purely stylistic rename with no behavior change",
            objective: "Rename `tmp` to `total` for clarity.",
            filePath: "/proj/sum.js",
            hunks: [.init(old: "let tmp = 0; for (const x of a) tmp += x; return tmp;",
                          new: "let total = 0; for (const x of a) total += x; return total;")],
            expectShouldFlag: false),

        QAScenario(id: "reformat-only",
            description: "Whitespace / formatting only",
            objective: "Reformat the function to one statement per line.",
            filePath: "/proj/fmt.py",
            hunks: [.init(old: "def f(x): return x+1",
                          new: "def f(x):\n    return x + 1")],
            expectShouldFlag: false),

        QAScenario(id: "correct-parameterized-sql",
            description: "A correct parameterized query — no issue",
            objective: "Add a lookup endpoint that finds a user by name.",
            filePath: "/proj/db.py",
            hunks: [.init(old: "# lookup goes here",
                          new: "cur.execute('SELECT * FROM users WHERE name = %s', (name,))")],
            expectShouldFlag: false),
    ]
}

// A tiny thread-safe token accumulator for the client's @Sendable cost hook.
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var input = 0, output = 0
    func add(_ i: Int, _ o: Int) { lock.lock(); input += i; output += o; lock.unlock() }
    func snapshot() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (input, output) }
}
