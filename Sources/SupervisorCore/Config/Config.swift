// Config.swift
//
// Decoded application config. v0.1.0 ships a small set; later versions
// add rubric path, daily cost cap, etc.
//
// Persistence format: YAML lands in v0.1.4 with Yams. For v0.1.0, config
// is constructed in-memory from defaults + Keychain lookup; nothing
// outside the API key is user-editable. Once Yams arrives, this struct
// will gain a `load(from:)` method.

import Foundation

public struct Config: Sendable, Equatable {

    /// Anthropic API base URL. Mostly here so tests can point at a mock.
    public var anthropicBaseURL: URL

    /// Triage model. Overridable in v0.1.x Settings; v0.1.0 hardcodes the
    /// default.
    public var triageModel: String

    /// Escalation model. Surfaces in Settings starting v0.1.1; v0.1.0 does
    /// not call this model at all.
    public var escalationModel: String

    /// Process-side "permission lost" flag, set by Inject/Notifier when
    /// they hit AX or notification-permission errors. Not persisted;
    /// recomputed on each launch.
    public var axPermissionLost: Bool

    public init(
        anthropicBaseURL: URL = URL(string: "https://api.anthropic.com")!,
        triageModel: String = "claude-haiku-4-5-20251001",
        escalationModel: String = "claude-sonnet-4-6",
        axPermissionLost: Bool = false
    ) {
        self.anthropicBaseURL = anthropicBaseURL
        self.triageModel = triageModel
        self.escalationModel = escalationModel
        self.axPermissionLost = axPermissionLost
    }

    /// The shipped defaults — what a fresh install gets.
    public static let defaults = Config()
}
