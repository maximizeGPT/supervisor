// ProposalGrounding.swift — TASK 2 (multi-session cross-project defense).
//
// A dispatch proposal for session S must be ABOUT S's project. The dispatcher
// reads S's transcript to propose work, and that transcript can be polluted
// (an earlier misrouted paste, a discussion of another project). Rather than
// scrub history, we make contamination INERT: before a proposal is emitted, we
// verify every concrete code symbol it names actually EXISTS in the git repo at
// S's own cwd. A landing-page proposal names landing-page files/components that
// do not exist in the supervisor repo, so it fails to ground and is dropped.
//
// This is the Swift mirror of the Python hook's _ground_proposal /
// _extract_code_symbols / _symbol_exists_in_repo (incl. the test-symbol
// fallback), grounding against a PER-SESSION cwd instead of a single repo.

import Foundation

/// Verifies a proposal grounds against a specific repo. Injected into the
/// Dispatcher so tests can supply a deterministic stub.
public protocol ProposalGrounding: Sendable {
    /// Concrete code symbols the proposal names that do NOT exist in the repo
    /// at `cwd`. Empty = grounded. A non-empty result means the proposal
    /// references code from a different project (cross-project leak) -> discard.
    func missingSymbols(inProposal proposal: String, cwd: String) async -> [String]

    /// Commit hashes the proposal cites that do NOT exist in the repo at `cwd`.
    /// Catches fabricated deploy-state claims ("commit abc123 shipped X / was
    /// never deployed") where the cited commit is invented. Default [] so stubs
    /// don't need to implement it.
    func missingCommits(inText text: String, cwd: String) async -> [String]
}

public extension ProposalGrounding {
    func missingCommits(inText text: String, cwd: String) async -> [String] { [] }
}

public struct RepoProposalGrounder: ProposalGrounding {

    private let gitPath: String
    private let timeout: TimeInterval
    private let trace: TraceLog

    public init(
        gitPath: String = "/usr/bin/env",
        timeout: TimeInterval = 8,
        trace: TraceLog = .shared
    ) {
        self.gitPath = gitPath
        self.timeout = timeout
        self.trace = trace
    }

    public func missingSymbols(inProposal proposal: String, cwd: String) async -> [String] {
        let symbols = Self.extractCodeSymbols(proposal)
        guard !symbols.isEmpty else { return [] }   // pure-prose proposal: nothing to ground
        var missing: [String] = []
        for sym in symbols.sorted() {
            if !(await symbolExists(sym, cwd: cwd)) {
                missing.append(sym)
                if missing.count >= 5 { break }     // enough to prove a leak
            }
        }
        return missing
    }

    // MARK: - Symbol extraction (mirror of Python _extract_code_symbols)

    /// Ordinary words / proper nouns that look code-shaped but aren't symbols
    /// the dispatcher must prove exist.
    static let groundingStopwords: Set<String> = [
        "claude_code", "product_direction", "owner_brief", "known_gaps",
        "low_confidence_no_action", "trial_notes", "product-direction.md",
        "owner-brief.md", "changelog.md", "principles.md", "readme.md",
        "trial-notes.md", "applescript", "electron",
    ]

    /// Extract concrete code-symbol-like tokens: snake_case identifiers,
    /// multi-word CamelCase types, and file.ext paths (code + web). Plain
    /// English and single-capitalized words are NOT symbols.
    static func extractCodeSymbols(_ text: String) -> [String] {
        var syms = Set<String>()
        func matches(_ pattern: String, group: Int = 0) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            let ns = text as NSString
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
                let r = m.range(at: group)
                return r.location != NSNotFound ? ns.substring(with: r) : nil
            }
        }
        // snake_case: at least one underscore joining alphanumerics.
        syms.formUnion(matches(#"[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+"#))
        // CamelCase types: two or more capitalized segments (LoopController).
        syms.formUnion(matches(#"\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+\b"#))
        // file.ext references — code and web file types so a landing-page
        // proposal naming page.tsx / Hero.jsx is caught.
        let exts = "swift|py|json|md|sh|txt|yaml|yml|plist|ts|tsx|js|jsx|css|scss|html|vue"
        syms.formUnion(matches(#"\b[\w/.-]+\.(?:\#(exts))\b"#))
        // Backtick-quoted code tokens (must look like an identifier/path).
        if let re = try? NSRegularExpression(pattern: #"`([^`]+)`"#) {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let identLike = t.range(of: #"^[\w./-]+$"#, options: .regularExpression) != nil
                let codeShaped = t.contains("_") || t.contains(".")
                    || t.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil
                if identLike && codeShaped { syms.insert(t) }
            }
        }
        return syms.filter { !groundingStopwords.contains($0.lowercased()) }
    }

    // MARK: - Existence check (mirror of Python _symbol_exists_in_repo)

    /// Prose excluded from the symbol search — a symbol mentioned only in docs
    /// is not proof of real code.
    private static let docExcludes = [
        ":(exclude,glob)**/*.md",
        ":(exclude,glob)OWNER-BRIEF*",
        ":(exclude,glob)CHANGELOG*",
        ":(exclude,glob)trial-notes*",
    ]
    /// Primary search also excludes tests (a symbol in a test STRING isn't
    /// proof of production code); test IDENTIFIERS get a fallback below.
    private static let codeExcludes = docExcludes + [
        ":(exclude,glob)**/*test*", ":(exclude,glob)**/*Test*",
    ]

    /// True if `symbol` is itself a test identifier (a `...Test`/`...Tests`
    /// class or a `test_foo`/`testFoo` method) — those live only in test files.
    static func isTestSymbol(_ symbol: String) -> Bool {
        symbol.range(of: #"Tests?$"#, options: .regularExpression) != nil
            || symbol.range(of: #"^test[_A-Z]"#, options: .regularExpression) != nil
    }

    private func symbolExists(_ symbol: String, cwd: String) async -> Bool {
        // A file/path symbol: check on disk, then by basename in code.
        if symbol.contains("/") || symbol.contains(".") {
            if FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(symbol)) {
                return true
            }
        }
        // Primary: code only (docs + tests excluded).
        if await gitGrepFound(symbol, cwd: cwd, excludes: Self.codeExcludes) { return true }
        // Tests-fallback: a real test class/helper lives only in a test file.
        if Self.isTestSymbol(symbol),
           await gitGrepFound(symbol, cwd: cwd, excludes: Self.docExcludes) {
            return true
        }
        return false
    }

    private func gitGrepFound(_ symbol: String, cwd: String, excludes: [String]) async -> Bool {
        let args = ["git", "grep", "-I", "-l", "-F", symbol, "--"] + excludes
        guard let result = try? await runProcess(
            executable: gitPath, args: args, cwd: cwd, timeout: timeout
        ) else { return false }
        // git grep exits 0 with output when found, 1 when not found.
        return result.exitCode == 0 && !(String(data: result.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Commit-existence (deploy-state grounding)

    /// Deploy/commit context words — only check cited hashes when the text makes
    /// a commit/deploy claim, so incidental hex (colors, ids) in unrelated
    /// proposals isn't flagged.
    private static let commitContextWords = [
        "commit", "deployed", "deploy", "shipped", "pushed", "cherry-pick",
        "cherry pick", "revision", " sha ", "merge", "rebase",
    ]

    public func missingCommits(inText text: String, cwd: String) async -> [String] {
        let lower = text.lowercased()
        guard Self.commitContextWords.contains(where: { lower.contains($0) }) else { return [] }
        let hashes = Self.extractCommitHashes(text)
        guard !hashes.isEmpty else { return [] }
        var missing: [String] = []
        for h in hashes {
            if !(await commitExists(h, cwd: cwd)) {
                missing.append(h)
                if missing.count >= 5 { break }
            }
        }
        return missing
    }

    /// Word-bounded lowercase hex, 7-40 chars (git short..full), requiring at
    /// least one a-f letter so a plain decimal number isn't treated as a hash.
    static func extractCommitHashes(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\b[0-9a-f]{7,40}\b"#) else { return [] }
        let ns = text as NSString
        var seen = Set<String>(); var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let h = ns.substring(with: m.range)
            if h.range(of: #"[a-f]"#, options: .regularExpression) == nil { continue }  // pure number
            if !seen.contains(h) { seen.insert(h); out.append(h) }
        }
        return out
    }

    private func commitExists(_ hash: String, cwd: String) async -> Bool {
        // `git cat-file -e <hash>^{commit}` exits 0 iff hash resolves to a commit.
        let r = try? await runProcess(
            executable: gitPath, args: ["git", "cat-file", "-e", "\(hash)^{commit}"],
            cwd: cwd, timeout: timeout
        )
        return r?.exitCode == 0
    }
}
