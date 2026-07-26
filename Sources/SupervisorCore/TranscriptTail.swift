// TranscriptTail.swift — shared helpers for reading a session transcript JSONL
// directly: the capped tail byte-window read and the transcript timestamp shape.
//
// EXTRACTED (issue #54 item 3) from private copies that had drifted into
// duplication: `readTailLines` lived verbatim in both AsyncWorkScanner (Triage)
// and MemoryDistiller (ContextWiki); `parseTS` lived in AsyncWorkScanner,
// EventParser, and CodexRolloutParser (all three behaviorally identical). Both
// concerns are facts about the transcript FILE FORMAT, not about any one
// consumer, so they live here — a small root-level utility rather than inside
// any subsystem directory.
//
// The consolidation also fixes a latent bug both tail-read copies shared: when
// the byte window opened mid-way through a multi-byte UTF-8 sequence,
// `String(data:encoding:)` returned nil and the ENTIRE tail was silently
// dropped — triage lost recent events, the second brain lost candidates. The
// shared reader now advances past leading continuation bytes before decoding,
// so at worst one partial character is lost instead of everything.

import Foundation

/// Shared, dependency-free helpers for code that reads a transcript JSONL
/// directly (tail scans, distillation, line parsing). A caseless enum: pure
/// static functions, no state.
enum TranscriptTail {

    /// Read the last `tailBytes` of the file and split into lines. Drops a
    /// leading partial LINE (the byte window may start mid-line). Returns nil
    /// on any read error (callers treat that as "no transcript"), [] for an
    /// empty file.
    ///
    /// UTF-8 boundary: a byte window that opens mid-way through a multi-byte
    /// sequence starts on a continuation byte (0b10xxxxxx), which would make
    /// `String(data:encoding:)` return nil and drop the whole tail. The window
    /// start is advanced past any leading continuation bytes to the first
    /// sequence-start byte before decoding — a UTF-8 sequence carries at most
    /// 3 continuation bytes, so the scan is bounded. The partial-character
    /// bytes belong to the partial line the next step drops anyway.
    static func readTailLines(_ url: URL, tailBytes: Int) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        // readToEnd() returns nil at EOF-with-no-data (an EMPTY file), not
        // just on error — the deleted originals guarded it with `try?` and so
        // returned nil for empty files, making their `isEmpty -> []` branch
        // unreachable (caught by CI on the consolidation's empty-file test).
        // The contract this utility pins: nil = could not read, [] = readable
        // but no content. Both callers treat the two identically ("nothing
        // to scan"), so mapping EOF-nil to empty data changes no outcome.
        var data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
        if data.isEmpty { return [] }
        if start > 0 {
            var partial = 0
            for byte in data.prefix(3) {
                guard byte & 0xC0 == 0x80 else { break }
                partial += 1
            }
            if partial > 0 { data.removeFirst(partial) }
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        // If we started mid-file, the first element is likely a partial line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    // MARK: - Timestamps

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse a transcript line's `timestamp` value: ISO 8601, with or without
    /// fractional seconds (both shapes appear on disk). nil for anything that
    /// is not a parseable string — callers pick their own fallback date.
    static func parseTS(_ raw: Any?) -> Date? {
        guard let str = raw as? String else { return nil }
        return isoFormatter.date(from: str) ?? isoFormatterNoFrac.date(from: str)
    }
}
