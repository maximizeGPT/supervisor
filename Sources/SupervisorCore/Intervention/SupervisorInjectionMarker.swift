// SupervisorInjectionMarker.swift
//
// Every turn Supervisor injects into a watched session lands in the JSONL
// transcript as a plain user-role turn — byte-identical to something the human
// operator typed. The driven agent (Claude Code) is STEERED by these injections,
// so it reads them as input and can act on them.
//
// HISTORY: an earlier design prefixed every injection with a visible banner +
// notice ("SUPERVISOR · automated — NOT from your operator" plus an
// authorization-boundary paragraph) so neither the driven agent nor a human
// reading along could mistake an injection for the operator. That stamp was
// removed by operator decision (the no-stamp decision: injections drive clean).
// Provenance is now carried OUT of band by the InjectionLedger, which records
// every injection at the injection boundary so Supervisor's own triage can
// recognize its injected turns without any in-text marker. The human gate is
// Claude self-gating on destructive actions, not a banner the operator did not
// want to read.
//
// `wrap` is kept as the single choke-point seam so the injector and the
// router still funnel through one place, but it now returns the body clean
// (identity). It also strips any legacy banner that might still be sitting in a
// re-queued dispatch, so old in-flight text reads clean too.

import Foundation

public enum SupervisorInjectionMarker {

    /// Legacy banner prefix. Retained ONLY so `wrap` can strip it from any
    /// re-queued / re-fired dispatch authored before the no-stamp decision; it
    /// is no longer prepended to new injections.
    static let legacyBanner = "⟦ SUPERVISOR · automated — NOT from your operator ⟧"

    /// Pass `body` (a drive proposal or an answer) through unchanged so the
    /// injected turn reads clean. Provenance for triage recognition comes from
    /// the InjectionLedger (recorded at the injection boundary), NOT from any
    /// in-text marker. If `body` still carries the legacy banner (a dispatch
    /// queued before the no-stamp decision), strip it so even old text drives
    /// clean. Idempotent.
    public static func wrap(_ body: String) -> String {
        guard body.hasPrefix(legacyBanner) else { return body }
        // Drop the banner line, the notice line, and the "———" separator that
        // the old format inserted, leaving the original body.
        var lines = body.components(separatedBy: "\n")
        // line 0: banner, line 1: notice, line 2: "———" — defensive against a
        // shorter shape (only strip what is actually present).
        if !lines.isEmpty { lines.removeFirst() }                 // banner
        if !lines.isEmpty { lines.removeFirst() }                 // notice
        if lines.first == "———" { lines.removeFirst() }           // separator
        return lines.joined(separator: "\n")
    }
}
