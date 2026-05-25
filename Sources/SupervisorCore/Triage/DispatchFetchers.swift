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
        // %x00 is a NUL separator — let us split fields without
        // collision with subject/body line breaks. %x1E (record sep)
        // between commits.
        let format = "%H%x00%s%x00%b%x1E"
        let args = [
            "git", "log",
            "\(baseBranch)..\(branch)",
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

    do {
        try proc.run()
    } catch {
        throw FetcherError.toolNotInstalled("\(executable) \(args.first ?? "") (\(error))")
    }

    // Race process termination against a timeout sleep. Whichever wins
    // determines what we do — finish-and-collect, or terminate-and-throw.
    return try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
        group.addTask {
            // Wait branch: blocks on the subprocess. waitUntilExit is
            // sync; wrap in a Task so we don't block the actor.
            await Task.detached { proc.waitUntilExit() }.value
            // Drain the pipes after the process is done. Reading
            // synchronously here is safe because the process has exited
            // and the pipes are closed on the write side.
            let stdout = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return ProcessResult(
                exitCode: proc.terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil  // sentinel meaning "timeout fired first"
        }

        defer { group.cancelAll() }
        for try await result in group {
            if let result {
                return result
            } else {
                // Timeout fired. SIGTERM the subprocess and throw.
                if proc.isRunning {
                    proc.terminate()
                }
                throw FetcherError.timedOut(tool: executable)
            }
        }
        // Group completed without a result (shouldn't happen — both
        // tasks return something) — treat as launch failure.
        throw FetcherError.toolNotInstalled(executable)
    }
}
