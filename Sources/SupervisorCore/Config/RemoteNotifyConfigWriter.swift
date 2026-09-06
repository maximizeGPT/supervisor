// RemoteNotifyConfigWriter.swift. The one writer for the `remote_notify`
// block in config.yaml.
//
// Until the hover panel grew a Remote escalation row, nothing in the app
// WROTE config.yaml — the file was owner-edited and live-reloaded by
// ConfigWatcher. The panel's on/off toggle and detail picker change that:
// they need to persist into the same file the owner may also be editing by
// hand, without clobbering anything else in it.
//
// Rules, in order of importance:
//
//   1. Only the `remote_notify` block is touched. Every other line —
//      comments, unknown keys, the owner's formatting — passes through
//      byte-for-byte. The owner's hand-written config is their file; the
//      app is a guest in it.
//   2. The result must round-trip through `UserConfig.parse`. The writer
//      uses the parser's own block-membership rule (a key belongs to the
//      block iff its indent is deeper than the header's), so a line this
//      writer emits is a line the parser reads back.
//   3. Never the webhook URL. The URL is a bearer credential and lives in
//      the Keychain (`KeychainRemoteNotifyURLStore`); config.yaml is a
//      plaintext file people paste into issues. This writer has no
//      parameter to accept a URL, so the mistake is unrepresentable.
//
// The disk write is atomic-via-rename (temp + rename in the same
// directory): an in-place truncate-and-write meant a crash or power cut
// mid-write could leave the owner's WHOLE config truncated — silently
// losing every hand-set key in it (daily_cap_usd, known_terminals, all of
// it), which is a far worse failure than the block this writer owns. The
// rename replaces the inode, which is exactly what atomic-save editors
// (vim and friends) already do; ConfigWatcher re-arms on the resulting
// delete/rename event, so live-reload survives the swap.

import Foundation

public enum RemoteNotifyConfigWriter {

    /// The desired `remote_notify` scalar values. A struct (not loose
    /// parameters) so a future key lands in one place instead of widening
    /// every call site.
    public struct Values: Sendable, Equatable {
        public var enabled: Bool
        public var detail: RemoteNotifyDetail
        /// C13: nil = auto-detect from the webhook host (written as
        /// `format: auto` so the key is visible and hand-editable).
        public var format: RemoteNotifyFormat?

        public init(enabled: Bool, detail: RemoteNotifyDetail, format: RemoteNotifyFormat? = nil) {
            self.enabled = enabled
            self.detail = detail
            self.format = format
        }
    }

    /// Pure text surgery: return `existing` with the `remote_notify` block's
    /// scalar keys set to `values`, creating the block (or the whole file
    /// body) when absent. Everything outside the block is preserved
    /// byte-for-byte, including a trailing newline's presence or absence
    /// being normalized to present (the file always ends in a newline so an
    /// appended block never glues onto the last line).
    public static func updatedYAML(_ existing: String?, values: Values) -> String {
        let enabledLine = "enabled: \(values.enabled ? "true" : "false")"
        let detailLine = "detail: \(values.detail.rawValue)"
        let formatLine = "format: \(values.format?.rawValue ?? "auto")"

        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return """
            remote_notify:
              \(enabledLine)
              \(detailLine)
              \(formatLine)

            """
        }

        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Splitting "a\n" yields ["a", ""]; drop that trailing empty element
        // and re-add the final newline on join so the round trip is stable.
        let hadTrailingNewline = existing.hasSuffix("\n")
        if hadTrailingNewline, lines.last == "" { lines.removeLast() }

        guard let headerIndex = lines.firstIndex(where: { isRemoteNotifyHeader($0) }) else {
            // No block yet: append one, separated by a blank line so it
            // reads as its own section in a hand-edited file.
            var out = lines
            if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("")
            }
            out.append("remote_notify:")
            out.append("  \(enabledLine)")
            out.append("  \(detailLine)")
            out.append("  \(formatLine)")
            return out.joined(separator: "\n") + "\n"
        }

        let headerIndent = indent(of: lines[headerIndex])
        let keyIndent = String(repeating: " ", count: headerIndent + 2)
        var replacedEnabled = false
        var replacedDetail = false
        var replacedFormat = false
        var index = headerIndex + 1

        // Walk the block by the parser's own membership rule: blanks and
        // comments pass through, a key line belongs iff indented deeper than
        // the header, and the first shallower non-blank line ends the block.
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            guard indent(of: line) > headerIndent else { break }
            let lineIndent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            // Rule 1 extends to the parts of a replaced line the parser
            // ignores: the owner's inline comment (everything from " #" on)
            // rides along onto the rewritten value, so "detail: minimal
            // # verdict only" toggled from the panel keeps its note.
            if trimmed.hasPrefix("enabled:"), !replacedEnabled {
                lines[index] = lineIndent + enabledLine + inlineComment(of: trimmed)
                replacedEnabled = true
            } else if trimmed.hasPrefix("detail:"), !replacedDetail {
                lines[index] = lineIndent + detailLine + inlineComment(of: trimmed)
                replacedDetail = true
            } else if trimmed.hasPrefix("format:"), !replacedFormat {
                lines[index] = lineIndent + formatLine + inlineComment(of: trimmed)
                replacedFormat = true
            }
            index += 1
        }

        // Missing keys are inserted right after the header, so they land
        // inside the block no matter what else the block holds. Reverse
        // order of appearance, so enabled ends up on top (insert reverses).
        if !replacedFormat { lines.insert(keyIndent + formatLine, at: headerIndex + 1) }
        if !replacedDetail { lines.insert(keyIndent + detailLine, at: headerIndex + 1) }
        if !replacedEnabled { lines.insert(keyIndent + enabledLine, at: headerIndex + 1) }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Read-modify-write `path`. Creates the file (and its parent
    /// directory) when absent. Atomic via temp + rename (see the file
    /// header): a reader sees the old file or the new one, never a
    /// truncated half.
    public static func write(values: Values, to path: URL) throws {
        let existing = try? String(contentsOf: path, encoding: .utf8)
        let updated = updatedYAML(existing, values: values)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try updated.write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Line classification (mirrors UserConfig.parse)

    /// Same header match the parser uses: comment-stripped, whitespace-
    /// trimmed equality, so a `remote_notify:  # switch` header is found.
    private static func isRemoteNotifyHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return false }
        let candidate = trimmed.components(separatedBy: " #").first?
            .trimmingCharacters(in: .whitespaces) ?? trimmed
        return candidate == "remote_notify:"
    }

    private static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).count
    }

    /// The inline comment on a key line: everything from the first " #"
    /// separator on (leading space included, so concatenation needs no
    /// glue), or "" when there is none. Mirrors the parser's own
    /// comment-stripping split — exactly what the parser ignores is what a
    /// rewrite must carry over. Values in this block are booleans and
    /// enum words, so a literal " #" inside a value cannot occur.
    private static func inlineComment(of trimmed: String) -> String {
        guard let range = trimmed.range(of: " #") else { return "" }
        return String(trimmed[range.lowerBound...])
    }
}
