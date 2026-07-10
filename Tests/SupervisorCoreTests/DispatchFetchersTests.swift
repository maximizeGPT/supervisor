// DispatchFetchersTests.swift
//
// Covers the fix for "dispatcher runs gh/git in an environment where they
// fail, every tick":
//   • PART A - resolveToolPath / resolveTool resolve the real binary path
//     (GUI-app PATH omits Homebrew, so `env gh` 127s); falling back to env
//     only when nothing is found, and building the right argv either way.
//   • PART B - the fetchers NEGATIVE-cache a failure so a second call within
//     the TTL returns empty WITHOUT re-invoking the runner (no per-tick
//     re-shell + re-log), and the git fetchers SKIP entirely outside a git
//     work tree instead of 128-ing every tick.
//
// The runner is injected so the cache/degrade decision is the seam under
// test, not Foundation's Process.

import XCTest
@testable import SupervisorCore

final class DispatchFetchersTests: XCTestCase {

    private func tmpTrace() -> TraceLog {
        TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-fetchers-\(UUID().uuidString).log"))
    }

    // MARK: - PART A: path resolution

    func testResolveToolPathReturnsFirstExisting() {
        // Only /usr/local/bin/gh "exists" - homebrew location does not.
        let exists = Set(["/usr/local/bin/gh", "/usr/bin/gh"])
        let path = resolveToolPath("gh", isExecutable: { exists.contains($0) })
        XCTAssertEqual(path, "/usr/local/bin/gh",
                       "must return the first probed location that exists (homebrew is skipped)")
    }

    func testResolveToolPathPrefersHomebrew() {
        // When homebrew has it, that wins (probed first).
        let exists = Set(["/opt/homebrew/bin/git", "/usr/bin/git"])
        XCTAssertEqual(resolveToolPath("git", isExecutable: { exists.contains($0) }),
                       "/opt/homebrew/bin/git")
    }

    func testResolveToolPathNilWhenNoneExist() {
        XCTAssertNil(resolveToolPath("gh", isExecutable: { _ in false }),
                     "no install location -> nil")
    }

    func testResolveToolUsesAbsolutePathAndDropsToolNameFromArgs() {
        // env sentinel passed + an absolute path found -> use it directly,
        // and the tool name is NOT prepended to args.
        let tool = resolveTool("gh", explicitPath: "/usr/bin/env",
                               isExecutable: { $0 == "/opt/homebrew/bin/gh" })
        XCTAssertEqual(tool.executable, "/opt/homebrew/bin/gh")
        XCTAssertFalse(tool.usedEnvFallback)
        let (exe, args) = tool.command(["issue", "list"])
        XCTAssertEqual(exe, "/opt/homebrew/bin/gh")
        XCTAssertEqual(args, ["issue", "list"], "absolute exe -> tool name must NOT be args[0]")
    }

    func testResolveToolFallsBackToEnvWhenNotFound() {
        // Nothing on disk -> env fallback, and the tool name IS args[0].
        let tool = resolveTool("gh", explicitPath: "/usr/bin/env",
                               isExecutable: { _ in false })
        XCTAssertEqual(tool.executable, "/usr/bin/env")
        XCTAssertTrue(tool.usedEnvFallback)
        let (exe, args) = tool.command(["issue", "list"])
        XCTAssertEqual(exe, "/usr/bin/env")
        XCTAssertEqual(args, ["gh", "issue", "list"], "env fallback -> tool name IS args[0]")
    }

    func testResolveToolHonorsExplicitInjectedPath() {
        // A test/override path (not the env sentinel) is used verbatim.
        let tool = resolveTool("git", explicitPath: "/tmp/fake-git")
        XCTAssertEqual(tool.executable, "/tmp/fake-git")
        XCTAssertFalse(tool.usedEnvFallback)
        XCTAssertEqual(tool.command(["log"]).args, ["log"])
    }

    // MARK: - PART B: negative caching (degrade once, not every tick)

    /// A counting runner that always fails to launch (the gh-not-installed
    /// case). Thread-safe so the actor can call it.
    private final class CountingFailRunner: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func run(_ executable: String, _ args: [String], _ cwd: String?, _ timeout: TimeInterval) async throws -> ProcessResult {
            lock.lock(); calls += 1; lock.unlock()
            throw FetcherError.toolNotInstalled("\(executable) (test)")
        }
    }

    /// A counting runner returning a non-zero exit (gh-not-authed case).
    private final class CountingNonZeroRunner: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        func run(_ executable: String, _ args: [String], _ cwd: String?, _ timeout: TimeInterval) async throws -> ProcessResult {
            lock.lock(); calls += 1; lock.unlock()
            return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("not logged in".utf8))
        }
    }

    func testIssueFetcherDegradesOnceLaunchFailure() async throws {
        let runner = CountingFailRunner()
        // explicit non-env path so resolveTool uses it directly (deterministic,
        // no real probe); the injected runner then fails the launch.
        let fetcher = GitHubIssueFetcher(
            cacheTTL: 60, timeout: 5, ghPath: "/fake/gh", trace: tmpTrace(),
            runner: runner.run
        )
        let first = try await fetcher.fetchOpenIssues(cwd: "/some/cwd")
        let second = try await fetcher.fetchOpenIssues(cwd: "/some/cwd")
        XCTAssertEqual(first, [], "launch failure degrades to empty")
        XCTAssertEqual(second, [], "second call within TTL also empty")
        XCTAssertEqual(runner.calls, 1,
                       "the runner must be invoked ONCE across two calls (negative cache)")
    }

    func testIssueFetcherDegradesOnceNonZeroExit() async throws {
        let runner = CountingNonZeroRunner()
        let fetcher = GitHubIssueFetcher(
            cacheTTL: 60, timeout: 5, ghPath: "/fake/gh", trace: tmpTrace(),
            runner: runner.run
        )
        _ = try await fetcher.fetchOpenIssues(cwd: "/cwd")
        _ = try await fetcher.fetchOpenIssues(cwd: "/cwd")
        XCTAssertEqual(runner.calls, 1,
                       "non-zero exit must also negative-cache (one shell across two ticks)")
    }

    func testCommitFetcherDegradesOnceLaunchFailure() async throws {
        let runner = CountingFailRunner()
        let fetcher = GitBranchCommitFetcher(
            cacheTTL: 30, timeout: 5, gitPath: "/fake/git", trace: tmpTrace(),
            runner: runner.run
        )
        let first = try await fetcher.fetchBranchCommits(cwd: "/cwd", branch: "feat", baseBranch: "main")
        let second = try await fetcher.fetchBranchCommits(cwd: "/cwd", branch: "feat", baseBranch: "main")
        XCTAssertEqual(first, [])
        XCTAssertEqual(second, [])
        // The non-repo guard (rev-parse) is the only runner call; it fails to
        // launch, so we degrade-cache and never re-invoke on the second tick.
        XCTAssertEqual(runner.calls, 1,
                       "git fetch must degrade once: one runner call across two ticks")
    }

    // MARK: - PART B: non-repo guard

    /// Runner that answers the rev-parse work-tree probe with "false" (not a
    /// repo) and would fail loudly if asked to run git log / diff afterwards.
    private final class NonRepoRunner: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var probeCalls = 0
        private(set) var nonProbeCalls = 0
        func run(_ executable: String, _ args: [String], _ cwd: String?, _ timeout: TimeInterval) async throws -> ProcessResult {
            lock.lock(); defer { lock.unlock() }
            if args.contains("--is-inside-work-tree") || args.contains("rev-parse") {
                probeCalls += 1
                // git rev-parse --is-inside-work-tree outside a repo: exit 128,
                // stdout empty (so isInsideGitWorkTree returns false).
                return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data("not a git repository".utf8))
            }
            nonProbeCalls += 1  // git log / diff - must NOT happen for a non-repo
            return ProcessResult(exitCode: 128, stdout: Data(), stderr: Data("fatal".utf8))
        }
    }

    func testCommitFetcherSkipsNonRepoWithoutGitLog() async throws {
        let runner = NonRepoRunner()
        let fetcher = GitBranchCommitFetcher(
            cacheTTL: 30, timeout: 5, gitPath: "/fake/git", trace: tmpTrace(),
            runner: runner.run
        )
        let commits = try await fetcher.fetchBranchCommits(cwd: "/not/a/repo", branch: "HEAD", baseBranch: "main")
        XCTAssertEqual(commits, [], "non-repo cwd yields empty commits")
        XCTAssertEqual(runner.nonProbeCalls, 0, "git log/diff must NOT run for a non-repo cwd")

        // Second tick within TTL: degrade is cached, so not even the probe re-runs.
        let again = try await fetcher.fetchBranchCommits(cwd: "/not/a/repo", branch: "HEAD", baseBranch: "main")
        XCTAssertEqual(again, [])
        XCTAssertEqual(runner.probeCalls, 1, "non-repo degrade is cached: the work-tree probe runs once, not every tick")
    }

    func testDiffStatFetcherSkipsNonRepoWithoutGitDiff() async throws {
        let runner = NonRepoRunner()
        let fetcher = GitDiffStatFetcher(
            cacheTTL: 30, timeout: 5, gitPath: "/fake/git", trace: tmpTrace(),
            runner: runner.run
        )
        let lines = try await fetcher.fetchDiffStat(cwd: "/not/a/repo", branch: "HEAD", baseBranch: "main")
        XCTAssertEqual(lines, [], "non-repo cwd yields empty diff stat")
        XCTAssertEqual(runner.nonProbeCalls, 0, "git diff must NOT run for a non-repo cwd")
    }

    // MARK: - PR fetcher: gh pr list JSON parsing + mergedAt->MERGED mapping

    /// A runner that returns canned `gh pr list` JSON stdout (exit 0). Counts
    /// calls so the per-cwd cache can also be exercised. Hermetic — no real gh.
    private final class CannedJSONRunner: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        private let json: String
        init(json: String) { self.json = json }
        func run(_ executable: String, _ args: [String], _ cwd: String?, _ timeout: TimeInterval) async throws -> ProcessResult {
            lock.lock(); calls += 1; lock.unlock()
            return ProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
        }
    }

    func testPRFetcherParsesGhJSONAndMapsMergedAt() async throws {
        // Three PRs: one OPEN, one CLOSED-with-mergedAt (must map to MERGED),
        // one CLOSED-without-mergedAt (stays CLOSED). gh emits mergedAt as an
        // ISO timestamp when merged and JSON null otherwise.
        let json = """
        [
          {"number": 34, "title": "code-review dimension", "state": "OPEN", "headRefName": "feat/review", "mergedAt": null, "updatedAt": "2026-07-05T10:00:00Z"},
          {"number": 31, "title": "multi-model panel", "state": "CLOSED", "headRefName": "feat/panel", "mergedAt": "2026-07-04T09:00:00Z", "updatedAt": "2026-07-04T09:00:00Z"},
          {"number": 20, "title": "abandoned spike", "state": "CLOSED", "headRefName": "spike/old", "mergedAt": null, "updatedAt": "2026-06-01T00:00:00Z"}
        ]
        """
        let runner = CannedJSONRunner(json: json)
        let fetcher = GitHubPRFetcher(
            cacheTTL: 60, timeout: 5, ghPath: "/fake/gh", trace: tmpTrace(),
            runner: runner.run
        )
        let prs = try await fetcher.fetchRecentPullRequests(cwd: "/some/repo")
        XCTAssertEqual(prs.count, 3)

        let open = prs.first { $0.number == 34 }
        XCTAssertEqual(open?.state, "OPEN", "OPEN with null mergedAt stays OPEN")
        XCTAssertEqual(open?.title, "code-review dimension")
        XCTAssertEqual(open?.headRefName, "feat/review")

        let merged = prs.first { $0.number == 31 }
        XCTAssertEqual(merged?.state, "MERGED",
                       "CLOSED with a non-null mergedAt must normalize to MERGED")

        let closed = prs.first { $0.number == 20 }
        XCTAssertEqual(closed?.state, "CLOSED",
                       "CLOSED with null mergedAt stays CLOSED (not merged)")

        // Second call within TTL hits the per-cwd cache — runner not re-invoked.
        _ = try await fetcher.fetchRecentPullRequests(cwd: "/some/repo")
        XCTAssertEqual(runner.calls, 1,
                       "per-cwd cache: one shell across two calls within TTL")
    }

    func testPRFetcherDegradesOnceLaunchFailure() async throws {
        let runner = CountingFailRunner()
        let fetcher = GitHubPRFetcher(
            cacheTTL: 60, timeout: 5, ghPath: "/fake/gh", trace: tmpTrace(),
            runner: runner.run
        )
        let first = try await fetcher.fetchRecentPullRequests(cwd: "/cwd")
        let second = try await fetcher.fetchRecentPullRequests(cwd: "/cwd")
        XCTAssertEqual(first, [], "launch failure degrades to empty")
        XCTAssertEqual(second, [], "second call within TTL also empty")
        XCTAssertEqual(runner.calls, 1,
                       "the runner must be invoked ONCE across two calls (negative cache)")
    }
}
