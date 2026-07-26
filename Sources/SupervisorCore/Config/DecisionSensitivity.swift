// DecisionSensitivity.swift - v0.2.0 observability (Reddit feedback E).
//
// The owner-tunable "how aggressively does Supervisor act vs. ask the human"
// scale. Two commenters asked exactly how Supervisor decides to interrupt a
// human vs. handle a situation confidently; this exposes that as a single,
// persisted setting the owner controls from the panel.
//
// The setting is a small three-stop scale - Cautious / Balanced / Decisive -
// stored in UserDefaults (so it survives relaunch and needs no rebuild). The
// MIDDLE stop, Balanced, is the DEFAULT and reproduces today's behavior
// EXACTLY: every threshold it feeds is its present value at Balanced, so a
// fresh install behaves identically to before this setting existed. Moving the
// dial only changes behavior away from that baseline.
//
// It maps onto the two real gates that decide act-vs-ask:
//   - the Evaluator pass threshold (the plan-step grader's bar; default 0.8).
//     Higher caution raises the bar (redirect/retry more), more decisive lowers
//     it (advance on a softer pass).
//   - the auto-answer confidence gate (the minimum self-reported confidence a
//     QuestionAnswerer engineering answer must carry to be injected rather than
//     escalated to the human as a notify). Cautious requires HIGH confidence
//     (only the surest answers act; medium escalates); Balanced injects medium+
//     (today's behavior: only LOW degrades); Decisive injects medium+ too but is
//     paired with the lower evaluator bar, so overall it acts more.
//
// Mirrors RuntimeToggles' shape (a tiny static facade over a persistence
// primitive) but uses UserDefaults rather than marker files: this is a scalar
// preference, not an on/off the hot path polls, and UserDefaults is the natural
// home for a stored enum preference. Reads are cheap and synchronous.

import Foundation

/// How aggressively Supervisor acts on its own vs. escalates to the human.
/// `.balanced` is the default and equals pre-setting behavior exactly.
public enum DecisionSensitivity: String, Sendable, Equatable, CaseIterable, Codable {
    /// Ask more. Raise the evaluator bar; only inject the surest (high-
    /// confidence) auto-answers, escalate the rest to the human.
    case cautious
    /// Today's behavior, unchanged. The default for every install.
    case balanced
    /// Act more. Lower the evaluator bar so borderline steps advance; still
    /// inject medium+ confidence answers.
    case decisive

    /// A short noun for the segmented control + labels.
    public var title: String {
        switch self {
        case .cautious: return "Cautious"
        case .balanced: return "Balanced"
        case .decisive: return "Decisive"
        }
    }

    /// One-line description shown under the control, plain language, no jargon.
    public var summary: String {
        switch self {
        case .cautious: return "Asks you more often. Only acts when it is very sure."
        case .balanced: return "The default balance of acting and asking."
        case .decisive: return "Acts more on its own. Asks you less often."
        }
    }

    // MARK: - Threshold mapping (the act-vs-ask gates)

    /// The Evaluator pass threshold this sensitivity selects. Balanced returns
    /// `Evaluator.defaultThreshold` (0.8) verbatim - the existing default - so
    /// the planner loop grades identically unless the owner moves the dial.
    /// Cautious raises the bar (harder to pass a step -> more redirect/retry);
    /// Decisive lowers it (a softer pass advances). Clamped into a sane band so
    /// no stop can make the grader trivially pass or never pass.
    public var evaluatorPassThreshold: Double {
        switch self {
        case .cautious: return 0.9
        case .balanced: return 0.8   // == Evaluator.defaultThreshold (no change)
        case .decisive: return 0.7
        }
    }

    /// The minimum auto-answer confidence that still INJECTS (acts) rather than
    /// escalating to the human as a notify. Balanced returns `.medium`, which is
    /// exactly today's gate: an engineering answer injects on high OR medium and
    /// only LOW (or an empty answer) degrades to a human-facing notify. Cautious
    /// tightens this to `.high` (medium now escalates - ask the human more);
    /// Decisive keeps `.medium` (acts as much as Balanced on answers, and acts
    /// MORE overall via its lower evaluator bar).
    public var minAnswerConfidenceToInject: EngineeringAnswer.Confidence {
        switch self {
        case .cautious: return .high
        case .balanced, .decisive: return .medium
        }
    }
}

/// Persisted accessor for the owner's decision-sensitivity setting. Static
/// facade over UserDefaults so any actor/thread can read it cheaply; the panel
/// writes it and the engine / planner-loop construction read it. Default
/// (no stored value) is `.balanced` -> identical to pre-setting behavior.
public enum DecisionSensitivityStore {

    /// The UserDefaults key. Namespaced so it never collides with another pref.
    public static let defaultsKey = "supervisor.decisionSensitivity"

    /// Read the current sensitivity. Returns `.balanced` when nothing is stored
    /// or the stored value is unrecognized (forward/backward safe).
    /// `defaults` is injectable for tests so a round-trip never touches the
    /// app's real `.standard` domain.
    public static func current(defaults: UserDefaults = SupervisorDefaults.shared) -> DecisionSensitivity {
        guard let raw = defaults.string(forKey: defaultsKey),
              let value = DecisionSensitivity(rawValue: raw) else {
            return .balanced
        }
        return value
    }

    /// Persist a sensitivity. Survives relaunch; the engine and planner-loop
    /// construction read `current()` so the change applies (the engine on its
    /// next answer decision; the evaluator at the next planner-loop build).
    public static func set(_ value: DecisionSensitivity, defaults: UserDefaults = SupervisorDefaults.shared) {
        defaults.set(value.rawValue, forKey: defaultsKey)
    }
}

/// Confidence ordering helper so the engine can compare a parsed answer's
/// confidence against the sensitivity gate without spelling the ladder out at
/// the call site. `.low < .medium < .high`.
extension EngineeringAnswer.Confidence {
    /// A monotonic rank for comparison: low=0, medium=1, high=2.
    public var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    /// Whether this confidence meets or exceeds `minimum` - the act-vs-escalate
    /// test the sensitivity gate uses.
    public func meets(_ minimum: EngineeringAnswer.Confidence) -> Bool {
        rank >= minimum.rank
    }
}
