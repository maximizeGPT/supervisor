// ContextSourceScanner.swift — the "raw sources" half of the wiki pattern.
//
// Enumerates a project's Claude context surfaces under a root, READ-ONLY, and
// classifies each into a `RawSource`. Deterministic and side-effect-free: given
// the same tree it returns the same inventory, so the whole downstream pipeline
// (metrics -> wiki -> schema -> recommendations) is reproducible and testable.
//
// GENERAL, not hardcoded. The scanner understands the CONVENTIONS Claude Code
// uses — `CLAUDE.md`, `.claude/skills/<name>/SKILL.md`, `.claude/commands/*.md`,
// `AGENTS.md` — not any one user's directories. Point it at a code repo, at a
// bare `~/.claude`, or at a `skills/` directory and it finds what's there.
//
// WHAT IT WON'T DO. It never opens a file for WRITING and never follows a path
// out of the root. It skips the usual heavy/irrelevant trees (.git, node_modules,
// build outputs) so a real repo doesn't drown the inventory in vendored code.

import Foundation

public struct ContextSourceScanner: Sendable {

    /// Directory names never descended into: version control, dependency, and
    /// build-output trees. A CLAUDE.md vendored inside node_modules is not this
    /// project's context.
    public static let skippedDirNames: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", ".next", ".nuxt",
        "Pods", "Carthage", "vendor", ".venv", "venv", "__pycache__",
        ".mypy_cache", ".pytest_cache", "DerivedData", ".gradle", "target",
        ".terraform", ".turbo", "coverage", ".cache"
    ]

    /// File extensions treated as instruction TEXT (read for content/dup
    /// analysis). Anything else inside a skill dir is a `skillAsset`.
    public static let textExtensions: Set<String> = [
        "md", "markdown", "mdx", "txt", "text", "rst",
        "json", "jsonc", "yaml", "yml", "toml",
        "py", "sh", "bash", "zsh", "js", "mjs", "cjs", "ts", "rb", "swift"
    ]

    /// How deep to recurse. A generous default that reaches nested skill
    /// reference dirs without walking an entire monorepo.
    public let maxDepth: Int

    /// Extensions that are PROSE — content a Claude session loads as context. A
    /// subset of `textExtensions`: the rest (`.js`, `.py`, `.sh`, `.json`, …) are
    /// text but are executed/config, never read into the model's context, so they
    /// are inventoried as weight but excluded from duplication/size analysis.
    public static let proseExtensions: Set<String> = [
        "md", "markdown", "mdx", "txt", "text", "rst"
    ]

    public init(maxDepth: Int = 8) {
        self.maxDepth = maxDepth
    }

    /// Scan `root`, returning every context source found, sorted by path for a
    /// stable order. Missing/unreadable root -> empty (never throws: an audit of
    /// a nonexistent tree is simply "no sources", which the caller reports).
    public func scan(root: URL) -> [RawSource] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        var out: [RawSource] = []
        var visited: Set<String> = []
        walk(dir: root, depth: 0, into: &out, visited: &visited, fm: fm)
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - Walk

    private func walk(dir: URL, depth: Int, into out: inout [RawSource], visited: inout Set<String>, fm: FileManager) {
        guard depth <= maxDepth else { return }
        // Cycle guard: real ~/.claude/skills setups symlink skill directories
        // (and a symlink can loop). Key visits on the RESOLVED real path so we
        // enter each real directory at most once, which makes following symlinks
        // safe below.
        let canonical = dir.resolvingSymlinksInPath().standardizedFileURL.path
        guard !visited.contains(canonical) else { return }
        visited.insert(canonical)

        // List entry NAMES from the RESOLVED directory path. This is what makes
        // symlinked skill directories work: `contentsOfDirectory(at: <symlink-to-
        // dir URL>)` returns nil, but listing the resolved real path succeeds. We
        // then rebuild each child by appending its name to the ORIGINAL `dir` URL,
        // so classified paths stay under the audited tree (`.../skills/<name>/...`),
        // which is what skill-name extraction keys on.
        //
        // No `.skipsHiddenFiles` equivalent: `contentsOfDirectory(atPath:)` already
        // includes dotfiles, so `.claude/` is descended (skipping hidden entries
        // would make the scanner blind to every skill and command).
        let listPath = dir.resolvingSymlinksInPath().path
        guard let names = try? fm.contentsOfDirectory(atPath: listPath) else { return }

        for name in names {
            let entry = dir.appendingPathComponent(name)
            var entryIsDir: ObjCBool = false
            // fileExists follows symlinks, so a symlinked child dir reads as a dir.
            guard fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir) else { continue }

            if entryIsDir.boolValue {
                if Self.skippedDirNames.contains(name) { continue }
                walk(dir: entry, depth: depth + 1, into: &out, visited: &visited, fm: fm)
            } else if let source = classify(file: entry, fm: fm) {
                out.append(source)
            }
        }
    }

    // MARK: - Classify

    /// Classify one file into a `RawSource`, or `nil` if it isn't a context
    /// surface we care about (a random source file NOT inside a skill dir, a
    /// lockfile, an image at the repo root, etc.).
    func classify(file: URL, fm: FileManager) -> RawSource? {
        let name = file.lastPathComponent
        let lowerName = name.lowercased()
        let ext = file.pathExtension.lowercased()
        let components = file.pathComponents
        let skill = skillName(for: components)

        // Determine the kind. Order matters: SKILL.md before generic skill text.
        let kind: RawSourceKind
        if lowerName == "claude.md" || lowerName == "claude.local.md" {
            kind = .claudeMd
        } else if lowerName == "agents.md" {
            kind = .agentsMd
        } else if lowerName == "skill.md" {
            kind = .skillManifest
        } else if lowerName == "settings.json" || lowerName == "settings.local.json" {
            kind = .settings
        } else if isCommandFile(components: components, ext: ext) {
            kind = .command
        } else if skill != nil {
            // Inside a skill directory: text -> reference, else asset.
            kind = Self.textExtensions.contains(ext) ? .skillReference : .skillAsset
        } else if ext == "md" || ext == "markdown" {
            // A top-level (non-skill, non-command) markdown doc: a linked context
            // doc (MISSION.md, PROJECTS.md, a README-style instruction file).
            kind = .contextDoc
        } else {
            // Not a context surface we track.
            return nil
        }

        let attrs = try? fm.attributesOfItem(atPath: file.path)
        let byteCount = (attrs?[.size] as? Int) ?? 0

        // We READ content only for instruction-text kinds (to count lines, pull a
        // title, and feed duplication analysis). settings.json is inventoried but
        // its content is never audited, so it is not "text" for our purposes.
        let shouldRead = kind.isInstructionText
        var lineCount = 0
        var title: String? = name
        var isProse = false
        if shouldRead, let contents = try? String(contentsOf: file, encoding: .utf8) {
            // A NUL byte means the extension lied about being text; treat as asset.
            if contents.contains("\0") {
                return RawSource(path: file.path, kind: skill != nil ? .skillAsset : .other,
                                 skill: skill, title: name, byteCount: byteCount, lineCount: 0, isText: false, isProse: false)
            }
            // Line count as an editor would report it: a trailing newline does
            // NOT add a phantom line. "a\nb\n" is 2 lines, not 3; "a\nb" is 2;
            // "a\n" is 1; "" is 0. (Splitting on "\n" over-counts newline-
            // terminated files by one, which could nudge a split-budget boundary.)
            if contents.isEmpty {
                lineCount = 0
            } else {
                let newlines = contents.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                lineCount = contents.hasSuffix("\n") ? newlines : newlines + 1
            }
            title = firstHeading(in: contents) ?? name
            // Prose = a .md/.txt-family file the model reads as context. A skill's
            // .js/.py/.sh scripts are instruction-text kinds (skillReference) but
            // NOT prose — they're executed, never loaded into context.
            isProse = Self.proseExtensions.contains(ext)
        }

        return RawSource(
            path: file.path,
            kind: kind,
            skill: skill,
            title: title,
            byteCount: byteCount,
            lineCount: lineCount,
            isText: shouldRead,
            isProse: isProse
        )
    }

    /// The skill this path belongs to, if any: the path component immediately
    /// after a `skills` component. Works for `.claude/skills/<name>/...` and for
    /// a root that IS a skills dir (`.../skills/<name>/...`).
    func skillName(for components: [String]) -> String? {
        guard let skillsIdx = components.lastIndex(where: { $0 == "skills" }),
              skillsIdx + 1 < components.count else { return nil }
        let candidate = components[skillsIdx + 1]
        // The candidate must be a directory level above the file itself (i.e.
        // not the filename). components includes the filename last, so as long as
        // skillsIdx+1 is not the final component, it's a skill dir name.
        guard skillsIdx + 1 < components.count - 1 else { return nil }
        return candidate
    }

    /// A command file is `*.md` living under a `commands` directory.
    private func isCommandFile(components: [String], ext: String) -> Bool {
        (ext == "md" || ext == "markdown") && components.contains("commands")
    }

    /// The first markdown ATX heading (`# ...`) in `contents`, trimmed of the
    /// leading hashes — a human label for the source. `nil` if none.
    func firstHeading(in contents: String) -> String? {
        for rawLine in contents.components(separatedBy: "\n").prefix(40) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let stripped = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty { return String(stripped.prefix(120)) }
            }
        }
        return nil
    }
}
