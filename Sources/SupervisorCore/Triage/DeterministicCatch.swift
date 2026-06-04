import Foundation

/// Deterministic catch-list for irreversible local-loss git commands.
///
/// Runs BEFORE model triage (see `TriageEngine.evaluate`). Returns a `Match`
/// ONLY for commands whose SYNTAX proves irreversible local data loss, and
/// `nil` for everything else — every ambiguous and every safe form — so those
/// fall through to normal model triage unchanged.
///
/// Rationale (PRINCIPLES §3b, §5, §6): for this narrow command family the
/// asymmetry is extreme. A false pause on an authorized `git checkout --`
/// costs the user a few seconds and a dismiss; a miss costs uncommitted work
/// permanently, with no recovery. So we do not want a probabilistic model in
/// the loop talking itself out of firing here. Authorization does NOT lower
/// the floor for this family.
///
/// Conservative by construction: if parsing is uncertain, return `nil`. We
/// would rather miss a catch (the model still triages it) than false-fire and
/// break the negative rate. `rm -rf` deliberately stays on the model path
/// this pass — its path discrimination (temp dirs, build artifacts) is harder
/// and the model is already behaving on it.
public enum DeterministicCatch {

    public struct Match: Equatable, Sendable {
        /// Canonical pattern label for the technical reasoning, e.g.
        /// "git reset --hard".
        public let pattern: String
        /// Human phrase describing the irreversible effect, e.g.
        /// "discards your uncommitted changes to src/auth.swift".
        public let effect: String
    }

    /// Examine a full command line. Any sub-command (split on shell
    /// separators) that matches a catch form fires.
    public static func match(_ command: String) -> Match? {
        for sub in subcommands(of: command) {
            if let m = matchGit(sub) { return m }
        }
        return nil
    }

    // MARK: - Splitting

    /// Split on `&&`, `||`, `;`, `|`, and newlines so a catch form buried in a
    /// compound line (`git reset --hard && echo ok`) is still examined.
    static func subcommands(of line: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        let ch = Array(line)
        var i = 0
        func flush() {
            if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur) }
            cur = ""
        }
        while i < ch.count {
            let c = ch[i]
            let n = i + 1 < ch.count ? ch[i + 1] : " "
            if c == "\n" || c == ";" || c == "|" || (c == "&" && n == "&") {
                flush()
                if (c == "&" && n == "&") || (c == "|" && n == "|") { i += 1 }
                i += 1
                continue
            }
            cur.append(c)
            i += 1
        }
        flush()
        return parts
    }

    /// Whitespace tokenizer with minimal surrounding-quote stripping. git
    /// destructive args rarely need shell quoting; exotic quoting just
    /// under-matches, which is safe.
    static func tokenize(_ s: String) -> [String] {
        s.split { $0 == " " || $0 == "\t" }.map { t -> String in
            var x = String(t)
            if x.count >= 2, let f = x.first, (f == "\"" || f == "'"), x.last == f {
                x = String(x.dropFirst().dropLast())
            }
            return x
        }.filter { !$0.isEmpty }
    }

    // MARK: - git dispatch

    static func isGit(_ t: String) -> Bool { t == "git" || t.hasSuffix("/git") }

    static func matchGit(_ sub: String) -> Match? {
        var t = tokenize(sub)
        while let f = t.first, f == "sudo" || f == "command" || f == "nice" { t.removeFirst() }
        guard let head = t.first, isGit(head) else { return nil }
        t.removeFirst()
        t = stripGlobalOptions(t)
        guard let verb = t.first else { return nil }
        let args = Array(t.dropFirst())
        switch verb {
        case "checkout": return matchCheckout(args)
        case "restore":  return matchRestore(args)
        case "branch":   return matchBranch(args)
        case "clean":    return matchClean(args)
        case "reset":    return matchReset(args)
        default:         return nil
        }
    }

    /// Skip `git -C <dir>`, `git -c <k=v>`, and bare global flags
    /// (`--no-pager`, `--git-dir=…`) that precede the verb.
    static func stripGlobalOptions(_ toks: [String]) -> [String] {
        var t = toks
        while let f = t.first, f.hasPrefix("-") {
            t.removeFirst()
            if (f == "-C" || f == "-c"), !t.isEmpty { t.removeFirst() }
        }
        return t
    }

    // MARK: - flag/arg helpers (flag scanning STOPS at `--`)

    static func flagTokens(_ a: [String]) -> [String] {
        var o: [String] = []
        for x in a {
            if x == "--" { break }
            if x.hasPrefix("-") && x != "-" { o.append(x) }
        }
        return o
    }

    static func shortFlags(_ a: [String]) -> Set<Character> {
        var s: Set<Character> = []
        for f in flagTokens(a) where !f.hasPrefix("--") {
            for c in f.dropFirst() { s.insert(c) }
        }
        return s
    }

    static func longFlags(_ a: [String]) -> Set<String> {
        var s: Set<String> = []
        for f in flagTokens(a) where f.hasPrefix("--") {
            if let n = f.dropFirst(2).split(separator: "=").first.map(String.init), !n.isEmpty {
                s.insert(n)
            }
        }
        return s
    }

    static func nonFlagArgs(_ a: [String]) -> [String] {
        var o: [String] = []
        var after = false
        for x in a {
            if x == "--" { after = true; continue }
            if after || !x.hasPrefix("-") { o.append(x) }
        }
        return o
    }

    // MARK: - per-form matchers

    /// `git checkout -- <pathspec>` or `git checkout .` discard working-tree
    /// changes. Bare `git checkout <word>` is ambiguous (branch vs file) and
    /// is NOT caught — it falls through to the model.
    static func matchCheckout(_ a: [String]) -> Match? {
        if let i = a.firstIndex(of: "--") {
            let paths = a[(i + 1)...].joined(separator: " ")
            return Match(pattern: "git checkout -- <pathspec>",
                         effect: "discards your uncommitted changes to \(paths.isEmpty ? "the named paths" : paths)")
        }
        if a.contains(".") {
            return Match(pattern: "git checkout .",
                         effect: "discards all your uncommitted working-tree changes")
        }
        return nil
    }

    /// `git restore <pathspec>` discards working-tree changes, EXCEPT when the
    /// only scope is `--staged` (that just unstages, no working-tree loss).
    static func matchRestore(_ a: [String]) -> Match? {
        let s = shortFlags(a), l = longFlags(a)
        let staged = l.contains("staged") || s.contains("S")
        let worktree = l.contains("worktree") || s.contains("W")
        if staged && !worktree { return nil }          // unstage only → safe
        let paths = nonFlagArgs(a)
        guard !paths.isEmpty else { return nil }        // no pathspec → nothing discarded
        return Match(pattern: "git restore <pathspec>",
                     effect: "discards your uncommitted changes to \(paths.joined(separator: " "))")
    }

    /// `git branch -D <branch>` force-deletes and may lose unmerged commits.
    /// Lowercase `-d` is safe-delete (refuses on unmerged) and is NOT caught.
    static func matchBranch(_ a: [String]) -> Match? {
        let s = shortFlags(a), l = longFlags(a)
        let force = l.contains("force") || s.contains("f")
        guard s.contains("D") || ((l.contains("delete") || s.contains("d")) && force) else { return nil }
        let names = nonFlagArgs(a)
        return Match(pattern: "git branch -D",
                     effect: "force-deletes the branch \(names.isEmpty ? "" : names.joined(separator: " ") + " ")and can lose unmerged commits")
    }

    /// `git clean -f` WITH `-d` and/or `-x`/`-X` deletes untracked (and
    /// ignored) files. `-n`/`--dry-run` is a preview and is NOT caught even
    /// when clustered (`-fdxn`).
    static func matchClean(_ a: [String]) -> Match? {
        let s = shortFlags(a), l = longFlags(a)
        if s.contains("n") || l.contains("dry-run") { return nil }   // preview → safe
        let force = s.contains("f") || l.contains("force")
        let scope = s.contains("d") || s.contains("x") || s.contains("X")
        guard force && scope else { return nil }
        let ignored = s.contains("x") || s.contains("X")
        return Match(pattern: "git clean -f",
                     effect: "deletes untracked\(ignored ? " and ignored" : "") files, which cannot be recovered")
    }

    /// `git reset --hard [<ref>]` discards working + staged changes. Bare
    /// `git reset`, `--soft`, `--mixed` only move HEAD/unstage and are safe.
    static func matchReset(_ a: [String]) -> Match? {
        guard longFlags(a).contains("hard") else { return nil }
        let ref = nonFlagArgs(a).first
        let effect = ref == nil
            ? "discards all your uncommitted and staged changes"
            : "discards all uncommitted and staged changes back to \(ref!)"
        return Match(pattern: "git reset --hard", effect: effect)
    }
}
