// RedactorTests.swift
//
// Comprehensive test suite for the v0.1.0 redaction pattern set. Two
// classes of test per pattern:
//
//   - Positive cases: real-shaped secrets that MUST be redacted.
//   - Negative cases: similar-but-not strings that MUST NOT be redacted
//     (i.e. false-positive guards).
//
// If any case here fails, no network code in Phase A is allowed to land.
// The Redactor is the gate between observation and Anthropic; a regression
// here means we leak.

import XCTest
@testable import SupervisorCore

final class RedactorTests: XCTestCase {

    private let redactor = DefaultRedactor()

    // MARK: - Anthropic keys

    func testRedactsAnthropicKey() {
        let input = "my key is sk-ant-api03-AbCdEf12345678_xyz-AbCdEf12345"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains("sk-ant-api03"))
        XCTAssertTrue(out.contains("<redacted:anthropic-key>"))
    }

    func testDoesNotRedactPlainSkPrefix() {
        // `sk-` alone is not a key.
        let input = "the prefix is sk- and that's it"
        XCTAssertEqual(redactor.redact(input), input)
    }

    // MARK: - Generic API keys

    func testRedactsGenericOpenAIStyleKey() {
        let input = "OPENAI_KEY=sk-AbCdEf1234567890abcdefghijklmnop12345678"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains("sk-AbCdEf"))
        XCTAssertTrue(out.contains("<redacted:api-key>"))
    }

    func testGenericKeyDoesNotEatAnthropicKey() {
        // Anthropic pattern runs first; generic pattern must not also touch
        // an already-redacted Anthropic key.
        let input = "sk-ant-api03-abcdefghij1234567890abcdefghij1234567890"
        let out = redactor.redact(input)
        XCTAssertEqual(
            out.components(separatedBy: "<redacted:").count - 1, 1,
            "exactly one redaction marker expected, got: \(out)"
        )
    }

    func testShortSkLooksLikeKeyButIsNotRedacted() {
        // 31 chars after prefix — under the 32 lower bound.
        let input = "sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  // sk- + 31
        XCTAssertEqual(redactor.redact(input), input)
    }

    // MARK: - GitHub tokens

    func testRedactsGitHubClassicToken() {
        let token = "ghp_" + String(repeating: "A", count: 36)
        let input = "TOKEN=\(token) blah"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains("<redacted:github-token>"))
    }

    func testRedactsGitHubFineGrainedToken() {
        let token = "github_pat_" + String(repeating: "B", count: 82)
        let input = "use \(token) for the call"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains("<redacted:github-token>"))
    }

    func testRedactsGitHubOAuthToken() {
        let token = "gho_" + String(repeating: "9", count: 36)
        XCTAssertTrue(redactor.redact(token).contains("<redacted:github-token>"))
    }

    func testGitHubTokenWrongLengthNotRedacted() {
        // 35 chars instead of 36 — should NOT match.
        let near = "ghp_" + String(repeating: "A", count: 35)
        XCTAssertEqual(redactor.redact(near), near)
    }

    func testRedactsGitHubServerSideTokens() {
        for prefix in ["ghs_", "ghr_", "ghu_"] {
            let token = prefix + String(repeating: "C", count: 36)
            let out = redactor.redact("token: \(token)")
            XCTAssertFalse(out.contains(token), "failed to redact \(prefix) token")
            XCTAssertTrue(out.contains("<redacted:github-token>"))
        }
    }

    func testGitHubUnknownPrefixNotRedacted() {
        // ghx_ is not a GitHub token family.
        let near = "ghx_" + String(repeating: "C", count: 36)
        XCTAssertEqual(redactor.redact(near), near)
    }

    // MARK: - GitLab / npm / Google tokens

    func testRedactsGitLabToken() {
        let token = "glpat-" + String(repeating: "x", count: 20)
        let out = redactor.redact("clone with \(token)")
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains("<redacted:gitlab-token>"))
    }

    func testShortGitLabTokenNotRedacted() {
        // 19 chars after the prefix — under the 20 lower bound.
        let near = "glpat-" + String(repeating: "x", count: 19)
        XCTAssertEqual(redactor.redact(near), near)
    }

    func testRedactsNpmToken() {
        let token = "npm_" + String(repeating: "a", count: 36)
        let out = redactor.redact("//registry.npmjs.org/:_authToken=\(token)")
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains("<redacted:npm-token>"))
    }

    func testNpmTokenWrongLengthNotRedacted() {
        // 35 chars instead of 36 — should NOT match.
        let near = "npm_" + String(repeating: "a", count: 35)
        XCTAssertEqual(redactor.redact(near), near)
    }

    func testRedactsGoogleAPIKey() {
        let key = "AIzaSy" + String(repeating: "D", count: 33)   // AIza + 35-char body
        let out = redactor.redact("maps key is \(key)")
        XCTAssertFalse(out.contains(key))
        XCTAssertTrue(out.contains("<redacted:google-api-key>"))
    }

    func testShortAIzaStringNotRedacted() {
        // Body under the fixed 35-char shape — not a Google key.
        let near = "AIzaSy" + String(repeating: "D", count: 20)
        XCTAssertEqual(redactor.redact(near), near)
    }

    // MARK: - Slack tokens

    func testRedactsSlackBotToken() {
        let token = "xoxb-1234567890-AbCdEfGhIjKlMnOp1234"
        XCTAssertTrue(redactor.redact(token).contains("<redacted:slack-token>"))
    }

    func testRedactsSlackUserToken() {
        let token = "xoxp-1234567890-1234567890-AbCdEf-fedcba"
        XCTAssertTrue(redactor.redact(token).contains("<redacted:slack-token>"))
    }

    // MARK: - AWS credentials (pair)

    func testRedactsAWSAccessKeyAndPairedSecret() {
        // 20-char AKIA + 40-char secret within 200 chars.
        let accessKey = "AKIAIOSFODNN7EXAMPLE"
        let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        let input = """
        export AWS_ACCESS_KEY_ID=\(accessKey)
        export AWS_SECRET_ACCESS_KEY=\(secret)
        """
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains(accessKey))
        XCTAssertFalse(out.contains(secret))
        // Both halves get the AWS placeholder.
        XCTAssertTrue(out.contains("<redacted:aws-credential>"))
    }

    func testRedactsAWSAccessKeyWithoutSecretNearby() {
        // AKIA appears but no 40-char secret within 200 chars. The key id
        // alone should still be redacted (it's diagnostic data).
        let accessKey = "AKIAIOSFODNN7EXAMPLE"
        let input = "the access key is \(accessKey) and we'll grab the secret separately"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains(accessKey))
        XCTAssertTrue(out.contains("<redacted:aws-credential>"))
    }

    func testAWSPatternIgnoresWrongPrefix() {
        // AKIB instead of AKIA — not an access key.
        let input = "AKIBIOSFODNN7EXAMPLE is not an AWS key"
        XCTAssertEqual(redactor.redact(input), input)
    }

    // MARK: - AWS credentials (standalone secret assignment)

    func testRedactsStandaloneAWSSecretAssignment() {
        // ~/.aws/credentials shape: the secret line with no AKIA id nearby,
        // so the pair pattern can't fire.
        let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        let input = "aws_secret_access_key = \(secret)"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains(secret))
        XCTAssertTrue(out.contains("aws_secret_access_key = <redacted:aws-credential>"))
    }

    func testAWSSecretAssignmentIgnoresLongerBlob() {
        // 41 base64 chars — the trailing lookahead pins the value at
        // exactly 40, so a longer blob must not half-match.
        let blob = String(repeating: "A", count: 41)
        let input = "aws_secret_access_key=\(blob)"
        XCTAssertEqual(redactor.redact(input), input)
    }

    // MARK: - JWT

    func testRedactsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4iLCJpYXQiOjE1MTYyMzkwMjJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let out = redactor.redact("token=\(jwt)")
        XCTAssertFalse(out.contains(jwt))
        XCTAssertTrue(out.contains("<redacted:jwt>"))
    }

    func testShortJWTLikeStringNotRedacted() {
        // Three short segments; below the 20-char minimum per segment.
        let input = "eyJ.eyJ.eyJ"
        XCTAssertEqual(redactor.redact(input), input)
    }

    // MARK: - PEM private keys

    func testRedactsPEMPrivateKeyBlock() {
        // Whole multiline block goes, surrounding output stays.
        let input = """
        writing key to disk
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEAfakebody0123456789
        moreFakeBody/lines+here==
        -----END RSA PRIVATE KEY-----
        done
        """
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains("MIIEpAIBAAKCAQEA"))
        XCTAssertFalse(out.contains("BEGIN RSA PRIVATE KEY"))
        XCTAssertTrue(out.contains("<redacted:private-key>"))
        XCTAssertTrue(out.contains("writing key to disk"))
        XCTAssertTrue(out.contains("done"))
    }

    func testDoesNotRedactPEMPublicKeyBlock() {
        // No "PRIVATE KEY" in the header — public keys are fine to send.
        let input = """
        -----BEGIN PUBLIC KEY-----
        MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJ
        -----END PUBLIC KEY-----
        """
        XCTAssertEqual(redactor.redact(input), input)
    }

    // MARK: - URL with credentials

    func testRedactsBasicAuthURL() {
        let input = "git clone https://alice:s3cret@github.com/maximizeGPT/secret-repo.git"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains("alice:s3cret"))
        // Host is preserved.
        XCTAssertTrue(out.contains("github.com/maximizeGPT/secret-repo.git"))
        XCTAssertTrue(out.contains("<redacted:url-credentials>"))
    }

    func testRedactsCredentialedQueryParam() {
        let input = "GET https://api.example.com/v1/resource?api_key=verysecret123&other=ok"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains("verysecret123"))
        XCTAssertTrue(out.contains("api_key=<redacted:url-credentials>"))
        XCTAssertTrue(out.contains("other=ok"))
    }

    func testRedactsMultipleQueryParamCases() {
        let cases = [
            "?token=abc123",
            "&access_token=xyz789",
            "&secret=hush",
            "&password=hunter2",
        ]
        for c in cases {
            let url = "https://example.com/path\(c)&visible=yes"
            let out = redactor.redact(url)
            XCTAssertTrue(out.contains("<redacted:url-credentials>"),
                          "failed to redact: \(url) -> \(out)")
            XCTAssertTrue(out.contains("visible=yes"))
        }
    }

    func testDoesNotRedactRandomQueryParam() {
        // `key=` in the URL is not in our credential vocabulary.
        let input = "https://example.com/?key=value&name=alice"
        XCTAssertEqual(redactor.redact(input), input)
    }

    func testDoesNotRedactPathSegmentsThatLookLikeKeys() {
        // Path contains `api_key` but not as a query parameter.
        let input = "https://example.com/v1/api_key/list"
        XCTAssertEqual(redactor.redact(input), input)
    }

    func testQueryParamRedactionStopsAtJSONQuote() {
        // Regression for the encoded-body second pass: the value class
        // excludes `"` and `\`, so redaction must stop at the JSON closing
        // quote instead of eating `","next":"..."` and corrupting the body.
        let encoded = #"{"url":"https://x.test/?token=abc123","next":"keep-me"}"#
        let out = redactor.redact(encoded)
        XCTAssertFalse(out.contains("abc123"))
        XCTAssertTrue(
            out.contains(#"token=<redacted:url-credentials>","next":"keep-me""#),
            "redaction consumed across the JSON string boundary: \(out)"
        )
    }

    // MARK: - Connection strings

    func testRedactsPostgresConnectionStringPassword() {
        let input = "psql postgres://admin:hunter2@db.internal:5432/prod"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains("hunter2"))
        // Username and host survive for triage context.
        XCTAssertTrue(out.contains("postgres://admin:<redacted:url-credentials>@db.internal:5432/prod"))
    }

    func testRedactsMongoDBSRVConnectionStringPassword() {
        let input = "mongodb+srv://app:s3cr3tpw@cluster0.mongodb.net/db"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains("s3cr3tpw"))
        XCTAssertTrue(out.contains("mongodb+srv://app:<redacted:url-credentials>@cluster0.mongodb.net/db"))
    }

    func testConnectionStringWithoutCredentialsUnchanged() {
        // Host:port but no `user:pass@` — nothing to redact.
        let input = "postgres://db.example.com:5432/mydb"
        XCTAssertEqual(redactor.redact(input), input)
    }

    // MARK: - Shell export

    func testRedactsExportValue() {
        let input = "export ANTHROPIC_API_KEY=sk-stub-not-real-but-keeps-shape"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains("sk-stub-not-real-but-keeps-shape"))
        // Variable name is preserved.
        XCTAssertTrue(out.contains("export ANTHROPIC_API_KEY=<redacted>"))
    }

    func testRedactsExportInMultilineShellOutput() {
        let input = """
        running setup
        export AWS_SECRET=wJalrXUtnFEMIabcd1234567890bPxRfiCYEXAMPLEKEY
        export GITHUB_TOKEN=ghp_realtoken_here_with_extra_chars
        all done
        """
        let out = redactor.redact(input)
        XCTAssertTrue(out.contains("export AWS_SECRET=<redacted>"))
        XCTAssertTrue(out.contains("export GITHUB_TOKEN=<redacted>"))
        XCTAssertTrue(out.contains("running setup"))
        XCTAssertTrue(out.contains("all done"))
    }

    func testDoesNotRedactExportWithoutEqualsValue() {
        // `export FOO` without `=` is just declaring the var to be exported
        // — no value to leak.
        let input = "export FOO"
        XCTAssertEqual(redactor.redact(input), input)
    }

    func testRedactsIndentedExportOnLaterLine() {
        // `(?m)^\s*export` needs a REAL newline before it. This is the
        // plaintext shape LLMClient now redacts before JSON-encoding; on
        // the encoded body (`\n` as two chars) this line anchor can never
        // fire.
        let input = "setting up environment\n  export SECRET_TOKEN=hunter2abc\ndone"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains("hunter2abc"))
        XCTAssertTrue(out.contains("export SECRET_TOKEN=<redacted>"))
    }

    // MARK: - Line-start regressions (plaintext-before-encoding)

    func testRedactsLineLeadingGitHubToken() {
        // A token at the start of a line: its leading `\b` sits right after
        // a newline. In plaintext that's a boundary; in a JSON-encoded body
        // the preceding char is the `n` of the `\n` escape and the boundary
        // vanishes. The redactor must see this shape as plaintext.
        let token = "ghp_" + String(repeating: "Z", count: 36)
        let input = "output\n\(token)"
        let out = redactor.redact(input)
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains("<redacted:github-token>"))
    }

    // MARK: - Idempotence

    func testRedactionIsIdempotent() {
        let input = """
        sk-ant-api03-realish-anthropic-key-shape-xyz1234567890
        ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        https://alice:s3cret@example.com/?api_key=topsecret
        export OPENAI_KEY=sk-1234567890abcdefghijklmnopqrstuvwxyz12345
        """
        let once = redactor.redact(input)
        let twice = redactor.redact(once)
        XCTAssertEqual(once, twice, "redacting twice must yield the same string")
    }

    // MARK: - Composition

    func testRedactsMultipleSecretsInOneBlob() {
        let blob = """
        Loading credentials...
        export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
        export AWS_SECRET=wJalrXUtnFEMIabcdefghijklmnopqrstuvwxyz123456
        export GITHUB_TOKEN=ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        export ANTHROPIC=sk-ant-api03-real-shape-abc123def456ghi789
        Hitting endpoint: https://bot:p4ss@hooks.slack.com/services/T00/B00
        Bearer eyJabcdefghij1234567890.eyJabcdefghij1234567890.eyJabcdefghij1234567890XX
        Done.
        """
        let out = redactor.redact(blob)

        // No raw secrets survive.
        XCTAssertFalse(out.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(out.contains("wJalrXUtnFEMIabcdef"))
        XCTAssertFalse(out.contains("ghp_BBBBBBBBBB"))
        XCTAssertFalse(out.contains("sk-ant-api03"))
        XCTAssertFalse(out.contains("bot:p4ss"))

        // Structural words DO survive.
        XCTAssertTrue(out.contains("Loading credentials..."))
        XCTAssertTrue(out.contains("export AWS_ACCESS_KEY_ID="))
        XCTAssertTrue(out.contains("hooks.slack.com"))
        XCTAssertTrue(out.contains("Done."))
    }

    // MARK: - Non-secret strings

    func testPlainProseUnchanged() {
        let input = """
        The eval harness runs Claude Sonnet 4.6 against the netsuite fixture suite.
        We measured 12/15 pass on baseline, 13/15 on Opus.
        """
        XCTAssertEqual(redactor.redact(input), input)
    }

    func testEmptyStringHandled() {
        XCTAssertEqual(redactor.redact(""), "")
    }

    func testCodeWithKeyNamesButNoSecrets() {
        let input = """
        let apiKey = config.apiKey
        if let token = headers["Authorization"] {
            print("found token")
        }
        """
        XCTAssertEqual(redactor.redact(input), input)
    }
}
