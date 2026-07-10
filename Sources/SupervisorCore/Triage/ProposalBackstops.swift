// ProposalBackstops.swift - v0.2.0 M2b.
//
// The deterministic anti-fabrication backstops, factored OUT of the
// Dispatcher so the Planner (M2b) and the Dispatcher share ONE copy of
// the grounding logic instead of two drifting forks. The Dispatcher's
// `static func premiseRejection / stalenessRejection /
// environmentClaimRejection` now forward to these; the Planner calls
// them directly on each proposed step's (objective + doneCriteria).
//
// These are the SYNCHRONOUS, string-only guards (no I/O):
//   - premiseRejection           - the proposal builds/wires machinery
//                                   that already exists (self-referential
//                                   runaway), or falsely claims an
//                                   existing component is missing.
//   - stalenessRejection         - the proposal near-verbatim repeats a
//                                   recent one (the "dispatch the same
//                                   task three times" failure).
//   - environmentClaimRejection  - the proposal fabricates an unblocking
//                                   precondition ("the API key is set;
//                                   sweeps are unblocked") that is false.
//
// The ASYNC, repo-backed grounding (cross-project symbol existence +
// deploy-state commit existence) lives in ProposalGrounding.swift and is
// already a shared protocol; both the Dispatcher and the Planner inject
// the same `ProposalGrounding` and call it the same way. Nothing here
// changes the Dispatcher's observable behavior - its statics delegate
// verbatim so the existing DispatcherTests keep passing.

import Foundation

/// Namespace for the deterministic, string-only proposal backstops shared
/// by the Dispatcher and the Planner. Pure functions, no state, no I/O.
public enum ProposalBackstops {

    // MARK: - Premise verification

    /// Root-cause premise verification. Returns a rejection reason if the
    /// proposal's premise is false in the current tree, else nil.
    ///
    /// The recurring runaway: a proposal to BUILD / WIRE the dispatch loop,
    /// the Dispatcher, the triage engine, the inject path - all of which
    /// already exist - i.e. the loop describing itself as work. This is the
    /// discipline a human applies by hand ("verify the premise: is this
    /// already done?"), enforced deterministically so neither the in-app
    /// loop nor the Planner can ever emit already-done, self-referential
    /// work.
    ///
    /// PRECISE by construction (phrase-anchored, not bag-of-words) so it
    /// rejects "build the Dispatcher" but NEVER "add a test for the
    /// dispatcher" or "fix the dispatcher's grounding" - only a build/wire
    /// verb applied directly to an existing component, or a false "X is not
    /// wired/built/missing" claim about one.
    public static func premiseRejection(proposal: String, justification: String) -> String? {
        let text = (proposal + " ⋄ " + justification).lowercased()

        // Core machinery that ALREADY EXISTS in this repo. Proposing to
        // build or wire any of these is a false premise (and the loop's
        // CLOSED rule: it dispatches PRODUCT work, never builds itself).
        let existing = [
            "dispatch loop", "dispatcher", "loopcontroller", "loop controller", "loopconfig",
            "triage engine", "triageengine", "inject path", "injector", "interventionrouter",
            "intervention router", "dispatch engine", "dispatch queue", "self-extender",
            "selfextender", "dispatch hook", "deterministic catch", "deterministiccatch",
            "questionanswerer", "question answerer", "hardcodedrubric",
        ]
        // Build-from-scratch verbs (NOT fix/improve/add-test/review/close,
        // those are legitimate work ON existing code).
        let buildVerbs = ["build ", "implement ", "wire up ", "wire the ", "stand up ",
                          "introduce ", "create the ", "create a ", "write the ", "design the "]
        // Prepositions that, between a build verb and a component, make the
        // component a MODIFIER, not the thing being built ("a test FOR the
        // dispatcher"). Bias toward allowing when one is present.
        let prepositions = [" for ", " of ", " to ", " about ", " on ", " with ", " in ", " into "]
        // False "it's not there" claims directly after a component.
        let missingSuffixes = [" is not wired", " is not built", " is missing", " does not exist",
                              " doesn't exist", " isn't wired", " is not implemented",
                              " is not yet wired", " is not yet built", " needs to be built",
                              " needs to be wired"]

        for comp in existing {
            guard let r = text.range(of: comp) else { continue }
            // Window just BEFORE the component: a build verb here (and no
            // intervening preposition) means the component is the build
            // object. Catches "build the CGEventPost-based Dispatcher"
            // (adjectives in between) but not "build a test for the
            // dispatcher".
            let winStart = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let before = String(text[winStart..<r.lowerBound])
            if buildVerbs.contains(where: { before.contains($0) }),
               !prepositions.contains(where: { before.contains($0) }) {
                return "build_existing(\(comp.replacingOccurrences(of: " ", with: "_")))"
            }
            // Window just AFTER the component: a false "not there" claim.
            let winEnd = text.index(r.upperBound, offsetBy: 18, limitedBy: text.endIndex) ?? text.endIndex
            let after = String(text[r.upperBound..<winEnd])
            if missingSuffixes.contains(where: { after.contains($0) }) {
                return "false_missing(\(comp.replacingOccurrences(of: " ", with: "_")))"
            }
        }
        return nil
    }

    // MARK: - Staleness

    /// Deterministic backstop against the stale-loop failure: re-proposing
    /// work already dispatched this run. Returns a reason if `proposal`
    /// substantially repeats any entry in `recent`, else nil.
    ///
    /// Similarity = Jaccard over prefix-stemmed significant tokens. Threshold
    /// 0.85 - deliberately HIGH, so this is a narrow backstop for
    /// near-verbatim repeats only. Numbers are kept as identity-bearing
    /// tokens, so sequential numbered work ("bucket 1" vs "bucket 2") stays
    /// well under threshold and is NOT blocked. Both sides need >=4
    /// significant tokens - too-short heads are not judged.
    public static func stalenessRejection(proposal: String, against recent: [String]) -> String? {
        let target = significantTokens(proposal)
        guard target.count >= 4 else { return nil }
        for prior in recent {
            let priorTokens = significantTokens(prior)
            guard priorTokens.count >= 4 else { continue }
            let overlap = target.intersection(priorTokens).count
            let union = target.union(priorTokens).count
            guard union > 0 else { continue }
            let jaccard = Double(overlap) / Double(union)
            if jaccard >= 0.85 {
                let pct = Int((jaccard * 100).rounded())
                return "\(pct)% overlap with recent dispatch \"\(prior.prefix(56))\""
            }
        }
        return nil
    }

    /// Lowercased, prefix-6 stemmed significant tokens for similarity. Strips
    /// punctuation/markdown and generic stopwords, and collapses
    /// morphological variants crudely via a 6-char prefix so
    /// "calibrate"/"calibration" both stem to "calibr". Numbers are KEPT
    /// regardless of length - "12", "2", "7" carry task identity (Issue #12,
    /// bucket 2, step 7), and keeping them is what lets sequential numbered
    /// work stay distinct. Deterministic; no model.
    public static func significantTokens(_ s: String) -> Set<String> {
        let cleaned = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : " " }
        let words = String(cleaned).split(separator: " ").map(String.init)
        // Generic loop/instruction filler that carries no task identity.
        let stop: Set<String> = [
            "the", "and", "for", "with", "this", "that", "into", "its", "you",
            "next", "task", "direction", "please", "lets", "let", "then", "run",
            "now", "your", "from", "have", "has", "will", "should", "make", "via",
            "per", "all", "any", "out", "use", "using", "still", "just", "not",
        ]
        return Set(
            words
                .filter { ($0.count >= 3 || $0.allSatisfy(\.isNumber)) && !stop.contains($0) }
                .map { String($0.prefix(6)) }
        )
    }

    // MARK: - Environment claims

    /// Deterministic guard against fabricating an UNBLOCKING PRECONDITION to
    /// justify blocked work - the live failure on 2026-06-04: "The
    /// ANTHROPIC_API_KEY is set; calibration sweeps are unblocked" when the
    /// key was absent. Returns a reason if the proposal asserts the
    /// key/sweep is AVAILABLE but `anthropicKey` is empty.
    ///
    /// `anthropicKey` defaults to this process's env, but CAVEAT:
    /// Supervisor.app may launch without the worker's shell env, so absence
    /// here isn't proof the sweep would lack a key. We still reject - the
    /// asymmetry favors it: a false-reject merely declines to AUTO-act on an
    /// expensive sweep, while a miss acts on fabricated-premise work. The
    /// param is injectable for tests.
    public static func environmentClaimRejection(
        proposal: String,
        justification: String,
        anthropicKey: String? = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    ) -> String? {
        guard assertsEnvironmentAvailability(proposal + " " + justification) else { return nil }
        if (anthropicKey ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "key/sweep asserted available but ANTHROPIC_API_KEY absent"
        }
        return nil
    }

    /// True if `text` POSITIVELY asserts the API key / live sweep is
    /// available. The required adjacency (subject + is/are/'s + optional
    /// adverb + positive predicate) means the honest negated inverse - "the
    /// key is NOT set", "sweeps are still blocked" - does NOT match, so the
    /// guard never fires on a truthful "it's blocked" statement.
    public static func assertsEnvironmentAvailability(_ text: String) -> Bool {
        let pattern = #"(?i)\b(anthropic[_ ]?api[_ ]?key|api[_ ]?key|the key|keys|sweep|sweeps|calibration|live[ -]?api)\b\s+(?:is|are|'s|was|were)\s+(?:now\s+|finally\s+|already\s+)?(set|present|available|configured|enabled|unblocked)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, range: range) != nil
    }
}
