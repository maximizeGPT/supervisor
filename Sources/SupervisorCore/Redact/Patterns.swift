// Patterns.swift
//
// The v0.1.0 redaction pattern set. Each pattern is exported and tested
// individually in RedactorTests so a regression in one family can't hide
// behind the others passing.
//
// The exact regex strings are intentionally inlined here — not loaded from
// config — so the build cannot ship without them and so reviewing the
// pattern set is one file read.

import Foundation

extension RedactionPattern {

    /// All v0.1.0 patterns, in apply order. Order matters: AWS first so the
    /// pair-secret lookahead runs before the generic base64-ish patterns
    /// might eat the secret half on their own.
    public static let defaults: [RedactionPattern] = [
        anthropicKey,
        awsKeyPair,
        githubClassicToken,
        githubFineGrainedToken,
        githubOAuthToken,
        slackToken,
        jwt,
        genericOpenAIKey,    // After the named keys so prefix-anchored ones win.
        urlBasicAuth,
        urlCredentialedQueryParam,
        shellExport,
    ]

    // MARK: - Provider-specific keys

    /// Anthropic API key. `sk-ant-` prefix is the giveaway.
    /// Live keys are ~95 chars total; pattern is liberal on length so test
    /// fixtures with truncated keys also redact.
    public static let anthropicKey = RedactionPattern(
        name: "anthropic-key",
        placeholder: "<redacted:anthropic-key>",
        kind: .regex(re(#"sk-ant-[A-Za-z0-9_\-]{8,}"#))
    )

    /// Generic OpenAI-style `sk-...` key with no provider prefix. Must run
    /// AFTER `anthropicKey` so `sk-ant-...` keys are caught by the more
    /// specific pattern first (idempotency: re-applying does nothing).
    /// Conservative length lower bound (32) avoids hitting `sk-stub` etc.
    public static let genericOpenAIKey = RedactionPattern(
        name: "api-key",
        placeholder: "<redacted:api-key>",
        kind: .regex(re(#"\bsk-(?!ant-)[A-Za-z0-9_\-]{32,}"#))
    )

    /// GitHub classic personal access token. 36 alphanumeric chars after the
    /// `ghp_` prefix.
    public static let githubClassicToken = RedactionPattern(
        name: "github-token",
        placeholder: "<redacted:github-token>",
        kind: .regex(re(#"\bghp_[A-Za-z0-9]{36}\b"#))
    )

    /// GitHub fine-grained PAT. `github_pat_` + 82 char body.
    public static let githubFineGrainedToken = RedactionPattern(
        name: "github-token",
        placeholder: "<redacted:github-token>",
        kind: .regex(re(#"\bgithub_pat_[A-Za-z0-9_]{82}\b"#))
    )

    /// GitHub OAuth user-to-server token.
    public static let githubOAuthToken = RedactionPattern(
        name: "github-token",
        placeholder: "<redacted:github-token>",
        kind: .regex(re(#"\bgho_[A-Za-z0-9]{36}\b"#))
    )

    /// Slack bot / user / app tokens.
    public static let slackToken = RedactionPattern(
        name: "slack-token",
        placeholder: "<redacted:slack-token>",
        kind: .regex(re(#"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#))
    )

    /// AWS access-key ID + paired secret within 200 chars. The access-key
    /// ID alone is not technically secret (it's an identifier), but
    /// surfacing it in a triage prompt opens the door to the secret being
    /// disclosed unintentionally — so we treat them together.
    public static let awsKeyPair = RedactionPattern(
        name: "aws-credential",
        placeholder: "<redacted:aws-credential>",
        kind: .awsAccessKeyAndSecret(
            re(#"\bAKIA[0-9A-Z]{16}\b"#),
            secretRegex: re(#"[A-Za-z0-9/+=]{40}"#)
        )
    )

    /// JSON Web Token. Three base64url segments separated by dots.
    /// Lower-bounded at 20 chars per segment to skip short fixtures like
    /// `eyJ.eyJ.eyJ`.
    public static let jwt = RedactionPattern(
        name: "jwt",
        placeholder: "<redacted:jwt>",
        kind: .regex(re(#"\beyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\b"#))
    )

    // MARK: - URL credentials

    /// `https://user:pass@host` — redacts the `user:pass` half only, keeps
    /// the host visible so the model can still reason about which service
    /// was contacted.
    public static let urlBasicAuth = RedactionPattern(
        name: "url-credentials",
        placeholder: "<redacted:url-credentials>",
        kind: .regexGroup(
            re(#"(?i)(https?://)([^/\s:@]+:[^/\s@]+)@"#),
            group: 2
        )
    )

    /// URL query parameter values for known credential-carrying keys.
    /// Match shape: `?api_key=VALUE` or `&token=VALUE` → value redacted.
    public static let urlCredentialedQueryParam = RedactionPattern(
        name: "url-credentials",
        placeholder: "<redacted:url-credentials>",
        kind: .regexGroup(
            re(#"(?i)([?&](?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|token|password|passwd|pwd)=)([^&\s#]+)"#),
            group: 2
        )
    )

    // MARK: - Shell

    /// `export FOO=value` — value redacted, leaves `export FOO=` so the
    /// presence (and variable name) is visible in the log.
    public static let shellExport = RedactionPattern(
        name: "shell-export",
        placeholder: "<redacted>",
        kind: .regexGroup(
            re(#"(?m)^(\s*export\s+[A-Za-z_][A-Za-z0-9_]*=)(\S+)"#),
            group: 2
        )
    )

    // MARK: - Helper

    /// Builds an NSRegularExpression or traps if the literal is malformed —
    /// these are constants, so a typo should fail loudly at first run.
    private static func re(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            fatalError("RedactionPattern: malformed regex \(pattern): \(error)")
        }
    }
}
