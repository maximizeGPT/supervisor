// PrinciplesResolver.swift
//
// Pure, testable selection of the PRINCIPLES.md body from an ordered
// list of candidate paths. The app ships three load sites
// (QuestionAnswerer, Dispatcher, PlanLoop) that historically each
// inlined the same "first candidate that reads non-empty wins" walk.
// That let a STUB PRINCIPLES.md embedded in a stray app bundle win:
// a backup bundle shipped a 3.8k-char stub while the real file is
// ~35k chars, so a tick serviced by that instance reasoned from a
// near-empty contract.
//
// This resolver fixes that by rejecting sub-threshold candidates as
// stubs and emitting a loud trace, falling through to the next
// candidate, and returning nil (the existing "no PRINCIPLES.md found"
// degrade) only if every candidate is a stub or unreadable.

import Foundation

public enum PrinciplesResolver {

    /// Minimum byte/char count for a candidate to be accepted as the
    /// real PRINCIPLES.md. The real file is ~35k chars; the known stub
    /// is ~3.8k. 8000 sits comfortably between: clearly above any stub
    /// yet well under the real file, so a legitimately trimmed
    /// PRINCIPLES.md still passes while the stub is rejected.
    public static let stubThreshold = 8000

    /// Result of resolving the principles text, carrying enough detail
    /// for the caller to construct the engine component and to emit a
    /// trace.
    public struct Resolved {
        /// The accepted PRINCIPLES.md body.
        public let text: String
        /// The path the accepted body was read from.
        public let path: URL
    }

    /// Walk `candidates` in order. For each, read its contents via
    /// `read` (injected so tests need no real files). Skip candidates
    /// that fail to read or are empty. Skip candidates that read but are
    /// below `stubThreshold` chars, reporting them through `onStub` (the
    /// caller logs a loud trace). Return the first candidate at or above
    /// the threshold, or nil if none qualifies.
    ///
    /// Pure aside from the injected `read`/`onStub` closures: same
    /// inputs produce the same decision, which is what the tests pin.
    public static func resolve(
        candidates: [URL],
        read: (URL) -> String?,
        onStub: (URL, Int) -> Void = { _, _ in }
    ) -> Resolved? {
        for url in candidates {
            guard let text = read(url), !text.isEmpty else { continue }
            if text.count < stubThreshold {
                // Looks like a stub: do NOT accept it, flag it loudly,
                // and keep looking for a real file in a later candidate.
                onStub(url, text.count)
                continue
            }
            return Resolved(text: text, path: url)
        }
        return nil
    }
}
