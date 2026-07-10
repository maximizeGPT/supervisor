// DispatchFetchers.swift — v0.4.0 Part B.
//
// Two shell-outs the Dispatcher needs:
//
//   1. `gh issue list --json number,title,body,labels --limit 50`
//      → [DispatchIssue]
//   2. `git log main..<branch> --pretty=format:%H%x00%s%x00%b --no-merges`
//      → [DispatchCommit]
//
// Both are mandatory-context-for-dispatch but optional-for-shipping:
// the Dispatcher continues with empty arrays when either fails. The
// gh fetch in particular fails in a few well-defined ways (gh not
// installed, gh not authenticated, repo doesn't have an `origin` remote,
// no network), and Supervisor needs to stay running through all of them
// — the spec is explicit that the dispatcher MUST work without gh.
//
// Both fetchers are wrapped in 10s timeouts so a wedged subprocess
// doesn't stall an idle dispatch indefinitely. Both maintain
// in-memory caches keyed by working directory + branch so consecutive
// idle dispatches in the same session re-use one fetch — issues
// change rarely (60s TTL), commits per burst (30s TTL).
//
// All process IO runs on a detached Task so the @MainActor caller
// (TriageEngine.evaluateIdle) doesn't block on subprocess wait.

import Foundation

// MARK: - Protocols for testability

/// The shape the Dispatcher's caller (TriageEngine) consumes. Two
/// protocols rather than one so a test can mock one side without the
/// other (e.g. test the gh-failure path with a real git path, or
/// vice versa).
public protocol IssueFetching: Sendable {
    /// Fetch open issues for the current repo. Throws on hard failure;
    /// caller maps "did this throw" to "empty list" so the dispatcher
    /// continues. 10s timeout enforced internally. May return cached
    /// results if a previous call within the TTL succeeded.
    func fetchOpenIssues(cwd: String) async throws -> [DispatchIssue]
}

public protocol BranchCommitFetching: Sendable {
    /// Fetch commits on `branch` since divergence from `baseBranch`
    /// (default "main"). Same timeout + cache shape as issue fetching.
    func fetchBranchCommits(cwd: String, branch: String, baseBranch: String) async throws -> [DispatchCommit]
}

public protocol PRFetching: Sendable {
    /// Fetch recent pull requests (open + merged/closed) for the repo `gh`
    /// resolves from the git remote at `cwd`. Same timeout + per-cwd cache +
    /// degrade-to-empty shape as issue fetching. Lets the dispatcher SEE PR
    /// state so it verifies instead of hallucinating.
    func fetchRecentPullRequests(cwd: String) async throws -> [DispatchPullRequest]
}

// MARK: - Errors

public enum FetcherError: Error, Sendable, Equatable {
    /// The subprocess (`gh` or `git`) couldn't be launched. Almost always
    /// means the tool isn't installed or isn't on PATH.
    case toolNotInstalled(String)
    /// The subprocess exited non-zero. `stderr` is the captured stderr,
    /// truncated for trace-safe size. Cases: `gh` not authenticated,
    /// `git` not in a repo, branch doesn't exist locally, etc.
    case nonZeroExit(tool: String, exitCode: Int32, stderr: String)
    /// 10-second timeout expired before the subprocess finished.
    case timedOut(tool: String)
    /// The subprocess succeeded but its output couldn't be parsed (gh
    /// schema change, git output unexpected). Caller should treat as
    /// empty-list, not as a hard failure.
    case parseFailure(tool: String, underlying: String)
}

// MARK: - Executable path resolution

/// A resolved subprocess invocation: the executable to launch plus the
/// arg prefix to prepend. Two shapes:
///   - absolute path resolved (e.g. /opt/homebrew/bin/gh): executable is
///     that path, argPrefix is [] (the tool name is NOT an argument).
///   - env fallback (/usr/bin/env): executable is /usr/bin/env, argPrefix
///     is [tool] (env searches PATH for the tool, passed as args[0]).
/// `command(_:)` joins the prefix with the tool-specific args so callers
/// never have to remember which shape they are in.
struct ResolvedTool: Sendable {
    let executable: String
    let argPrefix: [String]
    /// True when we fell back to env because no absolute path was found.
    /// A genuinely-not-installed tool still resolves to env here; the
    /// launch then fails with toolNotInstalled, which the negative cache
    /// catches so we degrade once rather than every tick.
    let usedEnvFallback: Bool

    /// Build the (executable, args) pair for a tool subcommand.
    /// `args` is the tool-specific argument list WITHOUT the tool name,
    /// e.g. ["issue", "list", ...] or ["log", ...].
    func command(_ args: [String]) -> (executable: String, args: [String]) {
        (executable, argPrefix + args)
    }
}

/// Probe the common install locations for `tool` and return the first that
/// is an executable file, else nil. `isExecutable` is injectable so a test
/// can simulate which locations exist without touching the real filesystem.
/// Order matches a Homebrew-first Mac: /opt/homebrew/bin (Apple Silicon
/// brew), /usr/local/bin (Intel brew / MacPorts), /usr/bin, /bin.
func resolveToolPath(
    _ tool: String,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
) -> String? {
    let candidates = [
        "/opt/homebrew/bin/\(tool)",
        "/usr/local/bin/\(tool)",
        "/usr/bin/\(tool)",
        "/bin/\(tool)",
    ]
    return candidates.first(where: isExecutable)
}

/// Resolve a `ResolvedTool` for `tool` honoring an explicitly-injected path.
/// If `explicitPath` differs from the env sentinel the caller passed a real
/// path (a test fake or a hard-coded location): use it directly as the
/// executable with no arg prefix. Otherwise probe the install locations; on
/// success use the absolute path, on failure fall back to env (so a tool
/// that gets installed later still works, and the negative cache absorbs the
/// per-tick cost when it is genuinely absent).
func resolveTool(
    _ tool: String,
    explicitPath: String,
    envSentinel: String = "/usr/bin/env",
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
) -> ResolvedTool {
    if explicitPath != envSentinel {
        // Caller passed a real executable path (test fake or override).
        return ResolvedTool(executable: explicitPath, argPrefix: [], usedEnvFallback: false)
    }
    if let abs = resolveToolPath(tool, isExecutable: isExecutable) {
        return ResolvedTool(executable: abs, argPrefix: [], usedEnvFallback: false)
    }
    // No absolute path found. Fall back to env; launch will likely fail
    // with toolNotInstalled, which the negative cache degrades once.
    return ResolvedTool(executable: envSentinel, argPrefix: [tool], usedEnvFallback: true)
}

/// The subprocess runner signature. The fetchers hold one (defaulting to the
/// real `runProcess`) so tests can inject a fake that fails / counts calls
/// without spawning a real process: the cache/degrade decision is the seam
/// under test, not Foundation's Process.
typealias ProcessRunner = @Sendable (_ executable: String, _ args: [String], _ cwd: String?, _ timeout: TimeInterval) async throws -> ProcessResult

/// The default runner: the real subprocess shell-out.
let defaultProcessRunner: ProcessRunner = { try await runProcess(executable: $0, args: $1, cwd: $2, timeout: $3) }

// MARK: - GitHub issue fetcher

/// Shells out to `gh issue list`. Caches per-cwd for `cacheTTL` seconds.
/// Construct one per app, share across all dispatches.
public actor GitHubIssueFetcher: IssueFetching {

    // A cache entry holds EITHER a success (issues) or a degrade marker
    // (issues == nil). Both honor the same TTL: a failure within the window
    // short-circuits to empty without re-shelling or re-logging, so an idle
    // dispatch flood degrades once per window rather than every tick.
    private struct CacheEntry {
        let issues: [DispatchIssue]?
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval
    private let timeout: TimeInterval
    private let trace: TraceLog
    private let ghPath: String
    private let runner: ProcessRunner

    public init(
        cacheTTL: TimeInterval = 60,
        timeout: TimeInterval = 10,
        ghPath: String = "/usr/bin/env",
        trace: TraceLog = .shared
    ) {
        self.cacheTTL = cacheTTL
        self.timeout = timeout
        self.ghPath = ghPath
        self.trace = trace
        self.runner = defaultProcessRunner
    }

    /// Test seam: inject a runner that fails / counts calls so the negative
    /// cache can be exercised without spawning a real `gh`.
    init(cacheTTL: TimeInterval, timeout: TimeInterval, ghPath: String, trace: TraceLog, runner: @escaping ProcessRunner) {
        self.cacheTTL = cacheTTL
        self.timeout = timeout
        self.ghPath = ghPath
        self.trace = trace
        self.runner = runner
    }

    public func fetchOpenIssues(cwd: String) async throws -> [DispatchIssue] {
        // Cache path — return immediately if within TTL. A degrade marker
        // (issues == nil) returns empty WITHOUT shelling or logging, so a
        // gh-not-installed environment degrades once per window, not per tick.
        if let cached = cache[cwd], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            if let issues = cached.issues {
                trace.emit("dispatch", "gh issues cache hit cwd=\(cwd) count=\(issues.count)")
                return issues
            }
            return []  // cached degrade: silent empty, no re-shell, no re-log
        }

        let start = Date()
        // Resolve gh to an absolute path. A GUI app launched by Finder/launchd
        // has a minimal PATH that omits Homebrew, so `env gh` 127s every tick;
        // resolving the real path makes gh actually work when installed.
        let tool = resolveTool("gh", explicitPath: ghPath)
        let (exe, args) = tool.command([
            "issue", "list",
            "--json", "number,title,body,labels",
            "--limit", "50",
            "--state", "open",
        ])
        let result: ProcessResult
        do {
            result = try await runner(exe, args, cwd, timeout)
        } catch let err as FetcherError {
            degrade(cwd: cwd, reason: "fetch ERROR \(err)")
            return []
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        if result.exitCode != 0 {
            let stderr = String(String(data: result.stderr, encoding: .utf8)?.prefix(400) ?? "")
            degrade(cwd: cwd, reason: "nonzero exit=\(result.exitCode) stderr=\(stderr) latency=\(latencyMs)ms")
            return []
        }

        let issues: [DispatchIssue]
        do {
            issues = try JSONDecoder().decode([DispatchIssue].self, from: result.stdout)
        } catch {
            degrade(cwd: cwd, reason: "parse failure: \(error) latency=\(latencyMs)ms")
            return []
        }

        cache[cwd] = CacheEntry(issues: issues, fetchedAt: Date())
        trace.emit("dispatch", "gh issues fetched count=\(issues.count) latency=\(latencyMs)ms cwd=\(cwd)")
        return issues
    }

    /// Record a degrade marker for `cwd` and log it ONCE (only when the
    /// marker is newly created). Subsequent ticks within the TTL hit the
    /// cached marker and return empty silently.
    private func degrade(cwd: String, reason: String) {
        cache[cwd] = CacheEntry(issues: nil, fetchedAt: Date())
        trace.emit("dispatch", "gh issues degraded (empty for \(Int(cacheTTL))s): \(reason) cwd=\(cwd)")
    }
}

// MARK: - GitHub pull-request fetcher

/// Shells out to `gh pr list --state all`. Caches per-cwd for `cacheTTL`
/// seconds. Exact structural mirror of GitHubIssueFetcher: same absolute-path
/// resolution (GUI-app PATH omits Homebrew, so `env gh` 127s every tick), same
/// per-cwd negative cache (degrade once per window, not per tick), same
/// graceful degrade-to-empty on any shell failure. Because `gh` resolves the
/// repo from the git remote at `cwd`, this works for WHATEVER user/repo the
/// watched session is in — nothing here is hardcoded to a user.
public actor GitHubPRFetcher: PRFetching {

    // A cache entry holds EITHER a success (prs) or a degrade marker
    // (prs == nil). Both honor the same TTL: a failure within the window
    // short-circuits to empty without re-shelling or re-logging, so an idle
    // dispatch flood degrades once per window rather than every tick.
    private struct CacheEntry {
        let prs: [DispatchPullRequest]?
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval
    private let timeout: TimeInterval
    private let trace: TraceLog
    private let ghPath: String
    private let runner: ProcessRunner

    public init(
        cacheTTL: TimeInterval = 60,
        timeout: TimeInterval = 10,
        ghPath: String = "/usr/bin/env",
        trace: TraceLog = .shared
    ) {
        self.cacheTTL = cacheTTL
        self.timeout = timeout
        self.ghPath = ghPath
        self.trace = trace
        self.runner = defaultProcessRunner
    }

    /// Test seam: inject a runner that fails / counts calls / returns canned
    /// JSON so the parse + negative cache can be exercised without spawning
    /// a real `gh`.
    init(cacheTTL: TimeInterval, timeout: TimeInterval, ghPath: String, trace: TraceLog, runner: @escaping ProcessRunner) {
        self.cacheTTL = cacheTTL
        self.timeout = timeout
        self.ghPath = ghPath
        self.trace = trace
        self.runner = runner
    }

    public func fetchRecentPullRequests(cwd: String) async throws -> [DispatchPullRequest] {
        // Cache path — return immediately if within TTL. A degrade marker
        // (prs == nil) returns empty WITHOUT shelling or logging, so a
        // gh-not-installed environment degrades once per window, not per tick.
        if let cached = cache[cwd], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            if let prs = cached.prs {
                trace.emit("dispatch", "gh prs cache hit cwd=\(cwd) count=\(prs.count)")
                return prs
            }
            return []  // cached degrade: silent empty, no re-shell, no re-log
        }

        let start = Date()
        // Resolve gh to an absolute path. A GUI app launched by Finder/launchd
        // has a minimal PATH that omits Homebrew, so `env gh` 127s every tick;
        // resolving the real path makes gh actually work when installed.
        let tool = resolveTool("gh", explicitPath: ghPath)
        let (exe, args) = tool.command([
            "pr", "list",
            "--state", "all",
            "--limit", "30",
            "--json", "number,title,state,headRefName,mergedAt,updatedAt",
        ])
        let result: ProcessResult
        do {
            result = try await runner(exe, args, cwd, timeout)
        } catch let err as FetcherError {
            degrade(cwd: cwd, reason: "fetch ERROR \(err)")
            return []
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        if result.exitCode != 0 {
            let stderr = String(String(data: result.stderr, encoding: .utf8)?.prefix(400) ?? "")
            degrade(cwd: cwd, reason: "nonzero exit=\(result.exitCode) stderr=\(stderr) latency=\(latencyMs)ms")
            return []
        }

        let prs: [DispatchPullRequest]
        do {
            prs = try JSONDecoder().decode([DispatchPullRequest].self, from: result.stdout)
        } catch {
            degrade(cwd: cwd, reason: "parse failure: \(error) latency=\(latencyMs)ms")
            return []
        }

        cache[cwd] = CacheEntry(prs: prs, fetchedAt: Date())
        trace.emit("dispatch", "gh prs fetched count=\(prs.count) latency=\(latencyMs)ms cwd=\(cwd)")
        return prs
    }

    /// Record a degrade marker for `cwd` and log it ONCE (only when the
    /// marker is newly created). Subsequent ticks within the TTL hit the
    /// cached marker and return empty silently.
    private func degrade(cwd: String, reason: String) {
        cache[cwd] = CacheEntry(prs: nil, fetchedAt: Date())
        trace.emit("dispatch", "gh prs degraded (empty for \(Int(cacheTTL))s): \(reason) cwd=\(cwd)")
    }
}

// MARK: - Branch commit fetcher

/// Shells out to `git log <base>..<branch>`. Caches per-(cwd, branch)
/// for `cacheTTL` seconds. Same structure as GitHubIssueFetcher.
public actor GitBranchCommitFetcher: BranchCommitFetching {

    private struct CacheKey: Hashable {
        let cwd: String
        let branch: String
        let baseBranch: String
    }
    // commits == nil is the degrade marker (same TTL short-circuit as the
    // issue fetcher): a non-repo cwd or a git failure degrades once per
    // window instead of 128-ing on every tick.
    private struct CacheEntry {
        let commits: [DispatchCommit]?
        let fetchedAt: Date
    }

    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheTTL: TimeInterval
    private let timeout: TimeInterval
    private let trace: TraceLog
    private let gitPath: String
    private let runner: ProcessRunner

    public init(
        cacheTTL: TimeInterval = 30,
        timeout: TimeInterval = 10,
        gitPath: String = "/usr/bin/env",
        trace: TraceLog = .shared
    ) {
        self.cacheTTL = cacheTTL
        self.timeout = timeout
        self.gitPath = gitPath
        self.trace = trace
        self.runner = defaultProcessRunner
    }

    /// Test seam: inject a runner that fails / counts calls so the negative
    /// cache + non-repo guard can be exercised without spawning real `git`.
    init(cacheTTL: TimeInterval, timeout: TimeInterval, gitPath: String, trace: TraceLog, runner: @escaping ProcessRunner) {
        self.cacheTTL = cacheTTL
        self.timeout = timeout
        self.gitPath = gitPath
        self.trace = trace
        self.runner = runner
    }

    public func fetchBranchCommits(
        cwd: String,
        branch: String,
        baseBranch: String = "main"
    ) async throws -> [DispatchCommit] {
        let key = CacheKey(cwd: cwd, branch: branch, baseBranch: baseBranch)
        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            if let commits = cached.commits {
                trace.emit("dispatch", "git commits cache hit branch=\(branch) count=\(commits.count)")
                return commits
            }
            return []  // cached degrade: silent empty, no re-shell, no re-log
        }

        // Resolve git to an absolute path (GUI-app PATH omits Homebrew).
        let tool = resolveTool("git", explicitPath: gitPath)

        // NON-REPO guard: a cwd outside a git work tree would make git log
        // fail 128 every tick. Check once, degrade-cache + log once if not.
        if !(await isInsideGitWorkTree(cwd: cwd, tool: tool, timeout: timeout, runner: runner)) {
            degrade(key: key, reason: "cwd not a git repo; skipping git fetches cwd=\(cwd)")
            return []
        }

        let start = Date()
        // Resolve the actual merge-base rather than assuming baseBranch
        // exists as a local ref. Falls back to branch~20 if unreachable.
        let logRange = await resolveDiffRange(
            cwd: cwd, branch: branch, baseBranch: baseBranch,
            tool: tool, timeout: timeout, trace: trace, runner: runner
        )
        let format = "%H%x00%s%x00%b%x1E"
        let (exe, args) = tool.command([
            "log",
            logRange,
            "--pretty=format:\(format)",
            "--no-merges",
        ])

        let result: ProcessResult
        do {
            result = try await runner(exe, args, cwd, timeout)
        } catch let err as FetcherError {
            degrade(key: key, reason: "fetch ERROR \(err) cwd=\(cwd) branch=\(branch)")
            return []
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        if result.exitCode != 0 {
            let stderr = String(String(data: result.stderr, encoding: .utf8)?.prefix(400) ?? "")
            degrade(key: key, reason: "nonzero exit=\(result.exitCode) stderr=\(stderr) latency=\(latencyMs)ms")
            return []
        }

        let raw = String(data: result.stdout, encoding: .utf8) ?? ""
        var commits: [DispatchCommit] = []
        for record in raw.split(separator: "\u{1E}", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let sha = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = String(parts[1])
            let body = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            commits.append(DispatchCommit(sha: sha, subject: subject, body: body))
        }

        cache[key] = CacheEntry(commits: commits, fetchedAt: Date())
        trace.emit("dispatch", "git commits fetched count=\(commits.count) branch=\(branch) latency=\(latencyMs)ms")
        return commits
    }

    /// Record a degrade marker for `key` and log it ONCE (when newly created).
    private func degrade(key: CacheKey, reason: String) {
        cache[key] = CacheEntry(commits: nil, fetchedAt: Date())
        trace.emit("dispatch", "git commits degraded (empty for \(Int(cacheTTL))s): \(reason)")
    }
}

// MARK: - Diff-stat fetcher

public protocol DiffStatFetching: Sendable {
    func fetchDiffStat(cwd: String, branch: String, baseBranch: String) async throws -> [String]
}

/// Shells out to `git diff --stat <base>..<branch>`. Uses merge-base
/// resolution to handle cases where the base branch isn't directly
/// reachable (e.g. shallow clones, detached HEADs).
public actor GitDiffStatFetcher: DiffStatFetching {
    private struct CacheKey: Hashable {
        let cwd: String
        let branch: String
        let baseBranch: String
    }
    // lines == nil is the degrade marker (same TTL short-circuit as the
    // other fetchers): a non-repo cwd or a git failure degrades once per
    // window instead of erroring on every tick.
    private struct CacheEntry {
        let lines: [String]?
        let fetchedAt: Date
    }

    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheTTL: TimeInterval
    private let timeout: TimeInterval
    private let trace: TraceLog
    private let gitPath: String
    private let runner: ProcessRunner

    public init(
        cacheTTL: TimeInterval = 30,
        timeout: TimeInterval = 10,
        gitPath: String = "/usr/bin/env",
        trace: TraceLog = .shared
    ) {
        self.cacheTTL = cacheTTL
        self.timeout = timeout
        self.gitPath = gitPath
        self.trace = trace
        self.runner = defaultProcessRunner
    }

    /// Test seam: inject a runner that fails / counts calls so the negative
    /// cache + non-repo guard can be exercised without spawning real `git`.
    init(cacheTTL: TimeInterval, timeout: TimeInterval, gitPath: String, trace: TraceLog, runner: @escaping ProcessRunner) {
        self.cacheTTL = cacheTTL
        self.timeout = timeout
        self.gitPath = gitPath
        self.trace = trace
        self.runner = runner
    }

    public func fetchDiffStat(
        cwd: String,
        branch: String,
        baseBranch: String = "main"
    ) async throws -> [String] {
        let key = CacheKey(cwd: cwd, branch: branch, baseBranch: baseBranch)
        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            if let lines = cached.lines { return lines }
            return []  // cached degrade: silent empty, no re-shell, no re-log
        }

        // Resolve git to an absolute path (GUI-app PATH omits Homebrew).
        let tool = resolveTool("git", explicitPath: gitPath)

        // NON-REPO guard: skip the diff entirely outside a git work tree so
        // we don't 128 every tick. Degrade-cache + log once.
        if !(await isInsideGitWorkTree(cwd: cwd, tool: tool, timeout: timeout, runner: runner)) {
            degrade(key: key, reason: "cwd not a git repo; skipping git fetches cwd=\(cwd)")
            return []
        }

        let diffRange = await resolveDiffRange(
            cwd: cwd, branch: branch, baseBranch: baseBranch,
            tool: tool, timeout: timeout, trace: trace, runner: runner
        )

        let result: ProcessResult
        do {
            let (exe, args) = tool.command(["diff", "--stat", diffRange])
            result = try await runner(exe, args, cwd, timeout)
        } catch let err as FetcherError {
            degrade(key: key, reason: "fetch ERROR \(err) cwd=\(cwd)")
            return []
        }

        if result.exitCode != 0 {
            let stderr = String(String(data: result.stderr, encoding: .utf8)?.prefix(400) ?? "")
            degrade(key: key, reason: "nonzero exit=\(result.exitCode) range=\(diffRange) stderr=\(stderr)")
            return []
        }

        let raw = String(data: result.stdout, encoding: .utf8) ?? ""
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        // Last line is the summary ("N files changed, ..."); keep it but cap
        // file lines to 30.
        guard !lines.isEmpty else {
            cache[key] = CacheEntry(lines: [], fetchedAt: Date())
            return []
        }
        let summary = lines.last.map { $0.contains("changed") ? $0 : nil } ?? nil
        var fileLines = summary != nil ? Array(lines.dropLast()) : lines
        fileLines = Array(fileLines.prefix(30))
        if let summary { fileLines.append(summary) }
        cache[key] = CacheEntry(lines: fileLines, fetchedAt: Date())
        trace.emit("dispatch", "git diff stat fetched lines=\(fileLines.count) range=\(diffRange)")
        return fileLines
    }

    /// Record a degrade marker for `key` and log it ONCE (when newly created).
    private func degrade(key: CacheKey, reason: String) {
        cache[key] = CacheEntry(lines: nil, fetchedAt: Date())
        trace.emit("dispatch", "git diff stat degraded (empty for \(Int(cacheTTL))s): \(reason)")
    }
}

// MARK: - Merge-base resolution (shared by commit + diff-stat fetchers)

/// Resolve the best diff range for comparing a branch against its base.
/// Tries merge-base with the base branch (and origin/ variant), using
/// HEAD as the comparison target (always valid). Falls back to HEAD~20
/// if neither base ref resolves.
///
/// Uses HEAD instead of the branch name because the branch name may not
/// resolve as a git ref in all contexts (e.g. when the hook runs with a
/// CWD that has a different HEAD, or when the branch name is stale).
/// HEAD is always valid and points to the current working tree state.
///
/// `tool` carries the resolved git executable (absolute path or env
/// fallback) + arg prefix, so this builds the correct argv either way.
func resolveDiffRange(
    cwd: String,
    branch: String,
    baseBranch: String,
    tool: ResolvedTool,
    timeout: TimeInterval,
    trace: TraceLog,
    runner: ProcessRunner = defaultProcessRunner
) async -> String {
    // Try branch first, then HEAD as fallback target for merge-base.
    let targets = branch == "HEAD" ? ["HEAD"] : [branch, "HEAD"]
    for target in targets {
        for baseRef in [baseBranch, "origin/\(baseBranch)"] {
            do {
                let (exe, args) = tool.command(["merge-base", baseRef, target])
                let result = try await runner(exe, args, cwd, timeout)
                if result.exitCode == 0 {
                    let sha = String(data: result.stdout, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !sha.isEmpty {
                        return "\(sha)..HEAD"
                    }
                }
            } catch {
                // merge-base failed — try next candidate
            }
        }
    }
    trace.emit("dispatch", "diff_range_fallback reason=no_merge_base branch=\(branch) base=\(baseBranch) using=HEAD~20..HEAD")
    return "HEAD~20..HEAD"
}

/// Cheap one-shot check that `cwd` is inside a git work tree, via a single
/// `git rev-parse --is-inside-work-tree`. Returns false on any failure
/// (not a repo, git missing, timeout): callers degrade-cache + log once so
/// a non-repo cwd does not 128 git log / git diff on every tick.
func isInsideGitWorkTree(
    cwd: String,
    tool: ResolvedTool,
    timeout: TimeInterval,
    runner: ProcessRunner = defaultProcessRunner
) async -> Bool {
    do {
        let (exe, args) = tool.command(["rev-parse", "--is-inside-work-tree"])
        let result = try await runner(exe, args, cwd, timeout)
        guard result.exitCode == 0 else { return false }
        let out = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out == "true"
    } catch {
        return false
    }
}

// MARK: - Repo context for question answering (D1)

/// Gather a compact snapshot of the repo state for the QuestionAnswerer:
/// current branch (flagged protected vs working), recent commits, and the
/// uncommitted changes a "should I commit this?" refers to. This is what
/// lets Supervisor answer a routine commit/push question from ACTUAL
/// context instead of escalating it to the human. Bounded by `timeout`;
/// returns whatever it could gather (empty only if git is unavailable).
func gatherRepoContextForAnswer(
    cwd: String,
    branch: String?,
    gitPath: String = "/usr/bin/env",
    timeout: TimeInterval = 5,
    trace: TraceLog = .shared
) async -> String {
    var sections: [String] = []

    // Resolve git to an absolute path so a GUI-app minimal PATH doesn't make
    // every rev-parse/log/status here 127 the way `env git` would.
    let tool = resolveTool("git", explicitPath: gitPath)

    var resolvedBranch = branch
    if resolvedBranch?.isEmpty != false {
        let (exe, args) = tool.command(["rev-parse", "--abbrev-ref", "HEAD"])
        if let r = try? await runProcess(
            executable: exe, args: args, cwd: cwd, timeout: timeout
        ), r.exitCode == 0 {
            resolvedBranch = String(data: r.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    if let b = resolvedBranch, !b.isEmpty {
        let isProtected = (b == "main" || b == "master")
        let note = isProtected
            ? " (PROTECTED branch — never auto-commit/push/merge here; that is a human call)"
            : " (working branch — routine commits and pushes are fine and reversible)"
        sections.append("Current branch: \(b)\(note)")
    }

    let logCmd = tool.command(["log", "-8", "--pretty=format:%h %s"])
    if let r = try? await runProcess(
        executable: logCmd.executable, args: logCmd.args, cwd: cwd, timeout: timeout
    ), r.exitCode == 0 {
        let log = String(data: r.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !log.isEmpty { sections.append("Recent commits:\n\(log)") }
    }

    let statusCmd = tool.command(["status", "--short"])
    if let r = try? await runProcess(
        executable: statusCmd.executable, args: statusCmd.args, cwd: cwd, timeout: timeout
    ), r.exitCode == 0 {
        let status = String(data: r.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status.isEmpty {
            sections.append("Working tree: clean (nothing staged or uncommitted).")
        } else {
            let count = status.split(separator: "\n").count
            sections.append("Uncommitted changes (\(count) file(s)):\n\(String(status.prefix(800)))")
        }
    }

    let result = sections.joined(separator: "\n\n")
    trace.emit("triage.answer", "repo_context gathered bytes=\(result.utf8.count) branch=\(resolvedBranch ?? "?")")
    return result
}

// MARK: - Known Gaps (the standing work record)

/// Read the "# Known Gaps" section of `trial-notes.md` at `cwd` — the standing
/// record of unfinished / unticketed / blocked work the dispatcher should
/// propose from. Without this the in-app loop never sees the backlog: a task
/// flagged in trial-notes.md was invisible to it, so when issues/commits gave
/// no clear move it FABRICATED one. Mirror of the Python hook's
/// `fetch_known_gaps`: from "# Known Gaps" to the next top-level "# " heading
/// (or a "---" rule). Returns "" if the file or section is absent. Bounded so a
/// long record can't dominate the dispatch prompt.
func readKnownGaps(cwd: String, maxChars: Int = 6000) -> String {
    let path = (cwd as NSString).appendingPathComponent("trial-notes.md")
    guard let content = try? String(contentsOfFile: path, encoding: .utf8),
          let markerRange = content.range(of: "# Known Gaps") else { return "" }
    let section = content[markerRange.lowerBound...]
    var result: [Substring] = []
    for (i, line) in section.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        if i > 0 {
            if line.hasPrefix("# ") && !line.hasPrefix("# Known Gaps") { break }
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
        }
        result.append(line)
    }
    let joined = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return String(joined.prefix(maxChars))
}

// MARK: - Process runner (the shared internals)

struct ProcessResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

/// Run a subprocess with a hard timeout. Returns ProcessResult on
/// success (whether the process exited zero or non-zero — the caller
/// checks exitCode). Throws FetcherError on launch failure or timeout.
///
/// Internal-visible so the tests can drive runProcess directly without
/// going through the actors above when they want to test the timeout /
/// error paths.
// IMPORTANT (2026-06-07 deadlock fix): this function MUST NOT park a
// thread on `proc.waitUntilExit()`. The prior implementation did
// `await Task.detached { proc.waitUntilExit() }`, which blocks a thread
// on the Swift-concurrency *cooperative* pool — capped at the core count.
// A child that doesn't exit promptly (or whose exit the blocked thread
// never services) starves that pool and wedges EVERY async task in the
// process: the in-app Dispatcher (which shells out to git for proposal
// grounding on every idle dispatch) goes silent, and `swift test` spins
// at ~100% CPU forever (reproduced in ProposalGroundingTests, which calls
// this via git). git itself returned in 10ms — the hang was purely this
// runner.
//
// The rewrite is fully event-driven:
//   • exit is signalled by Foundation's `terminationHandler` (no parked
//     thread), latched through `ProcessExitSignal` to survive the
//     fire-before-wait race;
//   • stdout/stderr are drained to EOF on a Dispatch *global* queue
//     (grows threads on demand — can't be starved, and can't deadlock on
//     a >64KB full pipe buffer the way drain-after-exit could);
//   • the timeout enforcer escalates SIGTERM → SIGKILL so a
//     signal-ignoring child can never hold us open.
func runProcess(
    executable: String,
    args: [String],
    cwd: String?,
    timeout: TimeInterval
) async throws -> ProcessResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }

    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe

    // Event-driven exit signal — fires from terminationHandler, so no
    // thread is ever parked waiting on the child.
    let exitSignal = ProcessExitSignal()
    proc.terminationHandler = { _ in exitSignal.fire() }

    do {
        try proc.run()
    } catch {
        proc.terminationHandler = nil
        throw FetcherError.toolNotInstalled("\(executable) \(args.first ?? "") (\(error))")
    }

    // Drain both pipes concurrently, OFF the cooperative pool, so a child
    // writing >64KB can't block on a full pipe buffer while we wait.
    async let outData: Data = readToEndOffCooperativePool(outPipe.fileHandleForReading)
    async let errData: Data = readToEndOffCooperativePool(errPipe.fileHandleForReading)

    // Timeout enforcer: if the child outlives `timeout`, terminate then
    // hard-kill it. Cancelled (and a no-op) if the child exits first.
    let timedOut = ProcessTimeoutFlag()
    let enforcer = Task {
        do {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        } catch {
            return  // cancelled — the child already exited
        }
        timedOut.set()
        if proc.isRunning {
            let pid = proc.processIdentifier
            proc.terminate()                                  // SIGTERM
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s grace
            if proc.isRunning { kill(pid, SIGKILL) }          // hard kill
        }
    }

    // The child always exits (naturally, or because the enforcer kills
    // it), so this wait always resumes — no deadlock.
    await exitSignal.wait()
    enforcer.cancel()

    if timedOut.value {
        throw FetcherError.timedOut(tool: executable)
    }
    return ProcessResult(
        exitCode: proc.terminationStatus,
        stdout: await outData,
        stderr: await errData
    )
}

/// One-shot exit latch. `fire()` (called from `terminationHandler`) wakes
/// every pending `wait()`, and any `wait()` issued after `fire()` returns
/// immediately. This closes the fire-before-wait race: the awaiting task
/// can never miss a child that exits before it starts waiting.
private final class ProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for c in pending { c.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }
}

/// Thread-safe one-way flag (set on the enforcer task, read on the caller).
private final class ProcessTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Read a file handle to EOF on a Dispatch global queue (NOT the
/// cooperative pool), bridged back to async. `readToEnd()` blocks until
/// the write end closes (child exit); running it on a global queue — which
/// spawns threads on demand — keeps the cooperative pool free so the rest
/// of the async runtime can't be starved.
private func readToEndOffCooperativePool(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
        DispatchQueue.global().async {
            let data = (try? handle.readToEnd()) ?? Data()
            cont.resume(returning: data)
        }
    }
}
