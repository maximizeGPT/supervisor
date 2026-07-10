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
        pemPrivateKey,       // Whole-block match; runs before line-level patterns.
        anthropicKey,
        awsKeyPair,
        awsSecretAssignment, // After the pair so the AKIA lookahead claims the secret first.
        githubClassicToken,
        githubFineGrainedToken,
        githubOAuthToken,
        githubServerToken,
        gitlabToken,
        npmToken,
        googleAPIKey,
        slackToken,
        stripeKey,           // sk_live_/sk_test_/rk_live_ — underscore-prefixed.
        stripeWebhookSecret, // whsec_
        sendgridKey,
        twilioKey,
        jwt,
        genericOpenAIKey,    // After the named keys so prefix-anchored ones win.
        urlBasicAuth,
        connectionStringCredentials,
        urlCredentialedQueryParam,
        shellExport,
        envAssignmentSecret, // Value-side .env dump shape; after shellExport (export-prefixed) catches its own.
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

    /// GitHub server-side tokens: server-to-server (`ghs_`), refresh
    /// (`ghr_`), user (`ghu_`). Same 36+ char body as classic PATs.
    public static let githubServerToken = RedactionPattern(
        name: "github-token",
        placeholder: "<redacted:github-token>",
        kind: .regex(re(#"\b(?:ghs|ghr|ghu)_[A-Za-z0-9]{36,}\b"#))
    )

    /// GitLab personal access token. `glpat-` prefix + 20+ char body.
    public static let gitlabToken = RedactionPattern(
        name: "gitlab-token",
        placeholder: "<redacted:gitlab-token>",
        kind: .regex(re(#"\bglpat-[A-Za-z0-9_\-]{20,}"#))
    )

    /// npm access token. `npm_` prefix + exactly 36 alphanumeric chars.
    public static let npmToken = RedactionPattern(
        name: "npm-token",
        placeholder: "<redacted:npm-token>",
        kind: .regex(re(#"\bnpm_[A-Za-z0-9]{36}\b"#))
    )

    /// Google API key. `AIza` prefix + exactly 35 chars of base64url-ish
    /// body — the shape is fixed, so no length slack needed.
    public static let googleAPIKey = RedactionPattern(
        name: "google-api-key",
        placeholder: "<redacted:google-api-key>",
        kind: .regex(re(#"\bAIza[0-9A-Za-z_\-]{35}"#))
    )

    /// Slack bot / user / app tokens.
    public static let slackToken = RedactionPattern(
        name: "slack-token",
        placeholder: "<redacted:slack-token>",
        kind: .regex(re(#"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#))
    )

    /// Stripe secret / restricted secret keys: `sk_live_`, `sk_test_`,
    /// `rk_live_`, `rk_test_`. `genericOpenAIKey` only matches the hyphenated
    /// `sk-` form, so these underscore-prefixed keys slipped through. Publishable
    /// `pk_` keys are deliberately excluded (not secret). Body lower-bounded at
    /// 16 so a truncated `sk_live_x` label is not redacted.
    public static let stripeKey = RedactionPattern(
        name: "stripe-key",
        placeholder: "<redacted:stripe-key>",
        kind: .regex(re(#"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#))
    )

    /// Stripe webhook signing secret. `whsec_` prefix + body.
    public static let stripeWebhookSecret = RedactionPattern(
        name: "stripe-webhook-secret",
        placeholder: "<redacted:stripe-webhook-secret>",
        kind: .regex(re(#"\bwhsec_[A-Za-z0-9]{16,}"#))
    )

    /// SendGrid API key. `SG.` + a 22-char selector + a 43-char secret, both
    /// base64url-ish. The two fixed-length segments make the shape unambiguous.
    public static let sendgridKey = RedactionPattern(
        name: "sendgrid-key",
        placeholder: "<redacted:sendgrid-key>",
        kind: .regex(re(#"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"#))
    )

    /// Twilio Account SID (`AC…`) and API Key SID (`SK…`) — the `AC`/`SK`
    /// prefix + exactly 32 lowercase-hex chars. Fixed shape, so no length slack.
    public static let twilioKey = RedactionPattern(
        name: "twilio-key",
        placeholder: "<redacted:twilio-key>",
        kind: .regex(re(#"\b(?:AC|SK)[a-f0-9]{32}\b"#))
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

    /// Standalone `aws_secret_access_key = <40-char secret>` assignment
    /// (also `:` separated, optionally quoted — the ~/.aws/credentials and
    /// env-file shapes). The pair pattern above only fires when the secret
    /// trails an AKIA id within 200 chars; config snippets often carry the
    /// secret line alone. Trailing lookahead pins the value at exactly 40
    /// chars so longer base64 blobs don't half-match.
    public static let awsSecretAssignment = RedactionPattern(
        name: "aws-credential",
        placeholder: "<redacted:aws-credential>",
        kind: .regexGroup(
            re(#"(?i)\b(aws_secret_access_key\s*[=:]\s*["']?)([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])"#),
            group: 2
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

    // MARK: - Private key material

    /// PEM private-key block — `-----BEGIN ... PRIVATE KEY-----` through
    /// the matching END line, whole block redacted. `[A-Z ]*` covers the
    /// RSA / EC / DSA / OPENSSH / ENCRYPTED variants; public keys and
    /// certificates (no "PRIVATE KEY") do not match. `[\s\S]*?` crosses
    /// newlines without needing dot-matches-newline, so this fires on
    /// plaintext and on the JSON-encoded body alike.
    public static let pemPrivateKey = RedactionPattern(
        name: "private-key",
        placeholder: "<redacted:private-key>",
        kind: .regex(re(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#))
    )

    // MARK: - URL credentials

    /// `https://user:pass@host` — redacts the `user:pass` half only, keeps
    /// the host visible so the model can still reason about which service
    /// was contacted. `"` and `\` are excluded from the credential classes
    /// so the encoded-body pass can't match across JSON string boundaries.
    public static let urlBasicAuth = RedactionPattern(
        name: "url-credentials",
        placeholder: "<redacted:url-credentials>",
        kind: .regexGroup(
            re(#"(?i)(https?://)([^/\s:@"\\]+:[^/\s@"\\]+)@"#),
            group: 2
        )
    )

    /// Non-HTTP connection strings — `postgres://user:pass@host` and
    /// friends. Masks the password half only, keeping username + host
    /// visible for triage context. Same JSON-safety exclusions as
    /// `urlBasicAuth`.
    public static let connectionStringCredentials = RedactionPattern(
        name: "url-credentials",
        placeholder: "<redacted:url-credentials>",
        kind: .regexGroup(
            re(#"(?i)\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|rediss?|amqps?)://[^/\s:@"\\]+:([^/\s@"\\]+)@"#),
            group: 1
        )
    )

    /// URL query parameter values for known credential-carrying keys.
    /// Match shape: `?api_key=VALUE` or `&token=VALUE` → value redacted.
    /// `"` and `\` are excluded from the value class — without that, this
    /// pattern applied to a compact JSON body can consume across JSON
    /// structure and corrupt the request.
    public static let urlCredentialedQueryParam = RedactionPattern(
        name: "url-credentials",
        placeholder: "<redacted:url-credentials>",
        kind: .regexGroup(
            re(#"(?i)([?&](?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|token|password|passwd|pwd)=)([^&\s#"\\]+)"#),
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

    /// Generic env-assignment secret — the dominant `.env` dump shape,
    /// `NAME=value` / `NAME: value` where the NAME contains SECRET/TOKEN/KEY/
    /// PASSWORD/PASSWD/APIKEY. `shellExport` only catches the `export`-prefixed
    /// form; this covers the bare assignment. Value-side only: `NAME=` stays
    /// visible, the value is redacted. Anchored to line start (`(?m)^`) so it
    /// cannot run across a compact JSON body, and the value class `\S+` stops
    /// at whitespace (mirrors `shellExport`). The `(?!<redacted)` guard skips a
    /// value a provider-specific pattern already replaced (e.g.
    /// `OPENAI_KEY=<redacted:api-key>`), so those keep their precise label and
    /// re-redaction stays idempotent.
    public static let envAssignmentSecret = RedactionPattern(
        name: "env-secret",
        placeholder: "<redacted:env-secret>",
        kind: .regexGroup(
            re(#"(?im)^(\s*[A-Z0-9_]*(?:SECRET|TOKEN|KEY|PASSWORD|PASSWD|APIKEY)[A-Z0-9_]*\s*[=:]\s*)(?!<redacted)(\S+)"#),
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
