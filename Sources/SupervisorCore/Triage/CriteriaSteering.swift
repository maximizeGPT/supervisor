// CriteriaSteering.swift - v0.2.0 M6. Prompt criteria steering for plan steps.
//
// Anthropic's "Harness design for long-running apps" includes "prompt criteria
// steering": bake the quality bar into the step instruction UP FRONT so the
// Generator's output is shaped before the first artifact, not only corrected
// after by the Evaluator. This type is the pure, testable distillation of that
// bar. It does ONE thing: given a PlanStep, return a concise quality-bar
// preamble to PREPEND to that step's injected spec.
//
// WHAT IT IS NOT. It does NOT inject, does NOT touch the loop, the ledger, or
// the marker. It is a pure function: (PlanStep) -> String. The live wiring
// (PlanLoop) prepends the returned preamble to the step's objective and emits
// the whole thing through the EXISTING marked + ledgered inject path, so the
// provenance banner and ledger record are unchanged. It only ADDS standing
// framing text to plan-step injections that already happen behind the planner
// opt-in; it introduces no new ungated behavior.
//
// TWO BARS.
//   - The GENERAL bar is ALWAYS present: meet the done-criteria exactly, make
//     the smallest correct change, stay in scope, and never claim success
//     without evidence (tests / real output). This is the standing quality
//     frame for every step.
//   - The DESIGN bar is appended ONLY when the step looks like UI / design work
//     (detected by a keyword heuristic on the step's title + objective). It is a
//     tight, injection-sized distillation of DESIGN.md / PRODUCT.md: use design
//     tokens not raw literals, ration one accent, build hierarchy with type +
//     spacing not color, keep spacing on the scale, keep motion restrained, and
//     avoid the generic-AI-app defaults (gradient hero, rounded-everything,
//     emoji, clashing colors).
//
// The whole preamble is injected on EVERY step, so it is kept deliberately
// compact. No em dashes anywhere (house rule).

import Foundation

/// Pure builder for the standing criteria-steering preamble prepended to a plan
/// step's injected spec. No state, no I/O; fully determined by its input. The
/// detector and the two bars are exposed as statics so each is unit-testable in
/// isolation, mirroring how ContextSteward exposes its thresholds.
public enum CriteriaSteering {

    // MARK: - The general bar (always present)

    /// The standing quality bar prepended to every plan step, regardless of kind.
    /// Short on purpose (it ships on every inject). Frames the work the step spec
    /// that follows describes: meet the rubric exactly, change the minimum, stay
    /// in scope, and prove success with real evidence rather than self-report.
    /// Plain language, no em dashes.
    public static let generalBar = """
    Quality bar for this step:
    - Meet this step's done-criteria exactly. They are the rubric you will be graded against on real output, not self-report.
    - Make the smallest correct change that satisfies them. Do not refactor or expand beyond what the step asks.
    - Stay within this step's scope. Later steps cover the rest of the plan; do not pull their work forward.
    - Do not claim success without evidence. Run the build / tests / command and let the actual result show the criteria are met.
    """

    // MARK: - The design bar (UI / design steps only)

    /// The additional bar appended for UI / design steps. A tight distillation of
    /// DESIGN.md + PRODUCT.md sized for injection: the one-accent rule, hierarchy
    /// via type + spacing not color, tokens over raw literals, restrained motion,
    /// and the explicit anti-slop list. Kept short. Plain language, no em dashes.
    public static let designBar = """
    Design bar (this step touches UI / design):
    - Use the design tokens / system values, not raw literals. No off-grid spacing, ad-hoc hex, or one-off durations.
    - Ration one accent color for primary / active / success only; everything else stays neutral. Do not introduce a second accent.
    - Build hierarchy with the type scale and spacing, not with color. Size, weight, and the muted/primary text split carry rank.
    - Keep spacing on the defined scale and motion short and purposeful. Motion confirms a change, it does not decorate.
    - Avoid the generic AI-app defaults: no gradient hero, rounded-everything, emoji, or clashing colors. Calm and precise, not flashy.
    """

    // MARK: - UI / design detection

    /// The keyword set that marks a step as UI / design work. Matched
    /// case-insensitively as substrings against the step's title + objective. A
    /// deliberately broad, conservative net: a false positive only adds a short
    /// design bar, a false negative just omits it (the general bar still applies).
    static let designKeywords: [String] = [
        "ui", "view", "screen", "design", "layout", "swiftui", "css",
        "component", "style", "button", "theme", "color", "colour",
        "font", "spacing", "padding", "icon", "panel", "widget",
    ]

    /// Does this step look like UI / design work? True when any design keyword
    /// appears (case-insensitively) in the step's title or objective. Pure.
    /// Exposed for direct unit testing of the heuristic.
    public static func isDesignStep(_ step: PlanStep) -> Bool {
        let haystack = (step.title + " " + step.objective).lowercased()
        return designKeywords.contains { keyword in
            containsWord(haystack, keyword)
        }
    }

    /// Substring match with light word-boundary guarding so a short token like
    /// "ui" does not fire on an unrelated word that merely contains those letters
    /// (e.g. "build", "require", "guide"). A keyword matches when it appears
    /// bounded by a non-alphanumeric character (or the string edge) on each side.
    /// `haystack` is assumed already lowercased; `keyword` is lowercase.
    private static func containsWord(_ haystack: String, _ keyword: String) -> Bool {
        guard !keyword.isEmpty else { return false }
        let scalars = Array(haystack.unicodeScalars)
        let needle = Array(keyword.unicodeScalars)
        guard scalars.count >= needle.count else { return false }
        let isWordScalar: (Unicode.Scalar) -> Bool = { s in
            CharacterSet.alphanumerics.contains(s)
        }
        var i = 0
        let lastStart = scalars.count - needle.count
        while i <= lastStart {
            if Array(scalars[i..<(i + needle.count)]) == needle {
                let beforeOK = i == 0 || !isWordScalar(scalars[i - 1])
                let afterIndex = i + needle.count
                let afterOK = afterIndex == scalars.count || !isWordScalar(scalars[afterIndex])
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    // MARK: - Compose the preamble

    /// The full criteria-steering preamble for `step`: the general bar always,
    /// plus the design bar when the step looks like UI / design work. Returned as
    /// a single block with NO trailing separator; the caller decides how to join
    /// it to the step's objective (and to any transient M5 checkpoint note). Pure.
    public static func preamble(for step: PlanStep) -> String {
        if isDesignStep(step) {
            return generalBar + "\n\n" + designBar
        }
        return generalBar
    }
}
