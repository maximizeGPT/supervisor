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

// MARK: - GitHub issue fetcher

/// Shells out to `gh issue list`. Caches per-cwd for `cacheTTL` seconds.
/// Construct one per app, share across all dispatches.
public actor GitHubIssueFetcher: IssueFetching {

    private struct CacheEntry {
        let issues: [DispatchIssue]
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheTTL: TimeInterval
    private let timeout: TimeInterval
    private let trace: TraceLog
    private let ghPath: String

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
    }

    public func fetchOpenIssues(cwd: String) async throws -> [DispatchIssue] {
        // Cache HIT path — return immediately if within TTL.
        if let cached = cache[cwd], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            trace.emit("dispatch", "gh issues cache hit cwd=\(cwd) count=\(cached.issues.count)")
            return cached.issues
        }

        let start = Date()
        // `/usr/bin/env gh issue list ...` — env lets us avoid hard-
        // coding the gh path (Homebrew vs MacPorts vs system).
        let args = [
            "gh", "issue", "list",
            "--json", "number,title,body,labels",
            "--limit", "50",
            "--state", "open",
        ]
        let result: ProcessResult
        do {
            result = try await runProcess(
                executable: ghPath,
                args: args,
                cwd: cwd,
                timeout: timeout
            )
        } catch let err as FetcherError {
            trace.emit("dispatch", "gh issues fetch ERROR \(err) cwd=\(cwd)")
            throw err
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        if result.exitCode != 0 {
            let stderr = String(String(data: result.stderr, encoding: .utf8)?.prefix(400) ?? "")
            trace.emit("dispatch", "gh issues fetch nonzero exit=\(result.exitCode) stderr=\(stderr) latency=\(latencyMs)ms")
            throw FetcherError.nonZeroExit(tool: "gh", exitCode: result.exitCode, stderr: stderr)
        }

        let issues: [DispatchIssue]
        do {
            issues = try JSONDecoder().decode([DispatchIssue].self, from: result.stdout)
        } catch {
            trace.emit("dispatch", "gh issues parse failure: \(error) latency=\(latencyMs)ms")
            throw FetcherError.parseFailure(tool: "gh", underlying: "\(error)")
        }

        cache[cwd] = CacheEntry(issues: issues, fetchedAt: Date())
        trace.emit("dispatch", "gh issues fetched count=\(issues.count) latency=\(latencyMs)ms cwd=\(cwd)")
        return issues
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
    private struct CacheEntry {
        let commits: [DispatchCommit]
        let fetchedAt: Date
    }

    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheTTL: TimeInterval
    private let timeout: TimeInterval
    private let trace: TraceLog
    private let gitPath: String

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
    }

    public func fetchBranchCommits(
        cwd: String,
        branch: String,
        baseBranch: String = "main"
    ) async throws -> [DispatchCommit] {
        let key = CacheKey(cwd: cwd, branch: branch, baseBranch: baseBranch)
        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            trace.emit("dispatch", "git commits cache hit branch=\(branch) count=\(cached.commits.count)")
            return cached.commits
        }

        let start = Date()
        // Resolve the actual merge-base rather than assuming baseBranch
        // exists as a local ref. Falls back to branch~20 if unreachable.
        let logRange = await resolveDiffRange(
            cwd: cwd, branch: branch, baseBranch: baseBranch,
            gitPath: gitPath, timeout: timeout, trace: trace
        )
        let format = "%H%x00%s%x00%b%x1E"
        let args = [
            "git", "log",
            logRange,
            "--pretty=format:\(format)",
            "--no-merges",
        ]

        let result: ProcessResult
        do {
            result = try await runProcess(
                executable: gitPath,
                args: args,
                cwd: cwd,
                timeout: timeout
            )
        } catch let err as FetcherError {
            trace.emit("dispatch", "git log fetch ERROR \(err) cwd=\(cwd) branch=\(branch)")
            throw err
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)

        if result.exitCode != 0 {
            let stderr = String(String(data: result.stderr, encoding: .utf8)?.prefix(400) ?? "")
            trace.emit("dispatch", "git log nonzero exit=\(result.exitCode) stderr=\(stderr) latency=\(latencyMs)ms")
            throw FetcherError.nonZeroExit(tool: "git", exitCode: result.exitCode, stderr: stderr)
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
}

// MARK: - Diff-stat fetcher

public protocol DiffStatFetching: Sendable {
    func fetchDiffStat(cwd: String, branch: String, baseBranch: String) async throws -> [String]
}

/// Shells out to `git diff --stat <base>..<branch>`. Uses merge-base
/// resolution to handle cases where the base branch isn't directly
/// reachable (e.g. shallow clones, detached HEADs).
public actor GitDiffStatFetcher: DiffStatFetching {
    private let timeout: TimeInterval
    private let trace: TraceLog
    private let gitPath: String

    public init(
        timeout: TimeInterval = 10,
        gitPath: String = "/usr/bin/env",
        trace: TraceLog = .shared
    ) {
        self.timeout = timeout
        self.gitPath = gitPath
        self.trace = trace
    }

    public func fetchDiffStat(
        cwd: String,
        branch: String,
        baseBranch: String = "main"
    ) async throws -> [String] {
        let diffRange = await resolveDiffRange(
            cwd: cwd, branch: branch, baseBranch: baseBranch,
            gitPath: gitPath, timeout: timeout, trace: trace
        )

        let result: ProcessResult
        do {
            result = try await runProcess(
                executable: gitPath,
                args: ["git", "diff", "--stat", diffRange],
                cwd: cwd,
                timeout: timeout
            )
        } catch let err as FetcherError {
            trace.emit("dispatch", "git diff stat ERROR \(err) cwd=\(cwd)")
            throw err
        }

        if result.exitCode != 0 {
            let stderr = String(String(data: result.stderr, encoding: .utf8)?.prefix(400) ?? "")
            trace.emit("dispatch", "git diff stat nonzero exit=\(result.exitCode) range=\(diffRange) stderr=\(stderr)")
            throw FetcherError.nonZeroExit(tool: "git", exitCode: result.exitCode, stderr: stderr)
        }

        let raw = String(data: result.stdout, encoding: .utf8) ?? ""
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        // Last line is the summary ("N files changed, ..."); keep it but cap
        // file lines to 30.
        guard !lines.isEmpty else { return [] }
        let summary = lines.last.map { $0.contains("changed") ? $0 : nil } ?? nil
        var fileLines = summary != nil ? Array(lines.dropLast()) : lines
        fileLines = Array(fileLines.prefix(30))
        if let summary { fileLines.append(summary) }
        trace.emit("dispatch", "git diff stat fetched lines=\(fileLines.count) range=\(diffRange)")
        return fileLines
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
func resolveDiffRange(
    cwd: String,
    branch: String,
    baseBranch: String,
    gitPath: String,
    timeout: TimeInterval,
    trace: TraceLog
) async -> String {
    // Try branch first, then HEAD as fallback target for merge-base.
    let targets = branch == "HEAD" ? ["HEAD"] : [branch, "HEAD"]
    for target in targets {
        for baseRef in [baseBranch, "origin/\(baseBranch)"] {
            do {
                let result = try await runProcess(
                    executable: gitPath,
                    args: ["git", "merge-base", baseRef, target],
                    cwd: cwd,
                    timeout: timeout
                )
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

    var resolvedBranch = branch
    if resolvedBranch?.isEmpty != false {
        if let r = try? await runProcess(
            executable: gitPath,
            args: ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd: cwd, timeout: timeout
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

    if let r = try? await runProcess(
        executable: gitPath,
        args: ["git", "log", "-8", "--pretty=format:%h %s"],
        cwd: cwd, timeout: timeout
    ), r.exitCode == 0 {
        let log = String(data: r.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !log.isEmpty { sections.append("Recent commits:\n\(log)") }
    }

    if let r = try? await runProcess(
        executable: gitPath,
        args: ["git", "status", "--short"],
        cwd: cwd, timeout: timeout
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
