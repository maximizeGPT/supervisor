// Redactor.swift
//
// Every observation going to the Anthropic API passes through here first.
// Patterns are the v0.1.0 set documented in DESIGN.md §8 item 3.
//
// Non-optional by design: `AnthropicClient` refuses to initialize without a
// Redactor and the API would have to be re-architected to bypass it.
//
// v0.1.0 ships pattern-based redaction only. Context-aware redaction (where
// a tool_use's file_path argument flags the entire tool_result content as
// sensitive) lands in v0.1.1 alongside Read/Edit/Write tool extraction —
// v0.1.0 only extracts Bash tool_calls, so the context-aware path is not
// exercised by what we actually send to Haiku.

import Foundation

/// Anything that produces redacted output from a string. Protocol exists so
/// tests can plug in a deterministic spy and so the AnthropicClient init can
/// accept the abstraction.
public protocol Redactor: Sendable {
    /// Returns a copy of `input` with all known secret patterns replaced
    /// with `<redacted:type>` placeholders. Idempotent: re-redacting a
    /// redacted string is a no-op.
    func redact(_ input: String) -> String
}

/// Production Redactor. Patterns are tested individually and as a stack.
public struct DefaultRedactor: Redactor {

    private let patterns: [RedactionPattern]

    public init(patterns: [RedactionPattern] = RedactionPattern.defaults) {
        self.patterns = patterns
    }

    public func redact(_ input: String) -> String {
        // Apply patterns in declared order. Order matters for the AWS pair:
        // the AKIA pattern matches its own access key AND looks forward 200
        // chars for a partnered secret, so it must run before the generic
        // base64-like patterns that might otherwise eat the secret first.
        // Cheaper patterns (literal-prefix) come before expensive lookahead
        // ones so we minimize work on the common no-match path.
        var out = input
        for pattern in patterns {
            out = pattern.apply(to: out)
        }
        return out
    }
}

/// One named pattern. A small enum vs. a protocol so the patterns ship as
/// data, not as a sprawl of small types.
public struct RedactionPattern: Sendable {

    public let name: String
    public let placeholder: String
    private let kind: Kind

    enum Kind: Sendable {
        /// Standard regex replacement: every match becomes `<redacted:name>`.
        case regex(NSRegularExpression)

        /// Regex with a single capture group; only the group is replaced.
        /// Used for `export VAR=VALUE` (we keep `export VAR=` visible) and
        /// for URL credentials.
        case regexGroup(NSRegularExpression, group: Int)

        /// AWS-style: match an AKIA access-key id, then look forward up to
        /// 200 characters for a 40-character base64-like secret. If found,
        /// both get redacted.
        case awsAccessKeyAndSecret(NSRegularExpression, secretRegex: NSRegularExpression)
    }

    init(name: String, placeholder: String, kind: Kind) {
        self.name = name
        self.placeholder = placeholder
        self.kind = kind
    }

    func apply(to input: String) -> String {
        switch kind {
        case .regex(let re):
            return Self.replaceAll(re, in: input, with: placeholder)
        case .regexGroup(let re, let group):
            return Self.replaceCaptureGroup(re, group: group, in: input, with: placeholder)
        case .awsAccessKeyAndSecret(let keyRe, let secretRe):
            return Self.replaceAWSPair(keyRe, secretRegex: secretRe, in: input, placeholder: placeholder)
        }
    }

    // MARK: - Helpers

    private static func replaceAll(
        _ regex: NSRegularExpression,
        in input: String,
        with placeholder: String
    ) -> String {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: placeholder
        )
    }

    private static func replaceCaptureGroup(
        _ regex: NSRegularExpression,
        group: Int,
        in input: String,
        with placeholder: String
    ) -> String {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = regex.matches(in: input, options: [], range: range)
        // Replace from the end so earlier ranges remain valid.
        var out = input
        for match in matches.reversed() {
            guard match.numberOfRanges > group else { continue }
            let groupRange = match.range(at: group)
            guard groupRange.location != NSNotFound,
                  let swiftRange = Range(groupRange, in: out) else { continue }
            out.replaceSubrange(swiftRange, with: placeholder)
        }
        return out
    }

    private static func replaceAWSPair(
        _ keyRegex: NSRegularExpression,
        secretRegex: NSRegularExpression,
        in input: String,
        placeholder: String
    ) -> String {
        let nsInput = input as NSString
        let fullRange = NSRange(location: 0, length: nsInput.length)
        let keyMatches = keyRegex.matches(in: input, options: [], range: fullRange)
        guard !keyMatches.isEmpty else { return input }

        // Plan replacements: each key match becomes the placeholder; if a
        // secret pattern is within 200 chars, it's also replaced.
        // We collect ranges and apply from end → start to keep offsets valid.
        struct Replacement { let range: NSRange }
        var replacements: [Replacement] = []
        for keyMatch in keyMatches {
            replacements.append(Replacement(range: keyMatch.range))
            // Look forward up to 200 chars for the secret.
            let afterStart = keyMatch.range.location + keyMatch.range.length
            let windowLen = min(200, nsInput.length - afterStart)
            if windowLen > 0 {
                let windowRange = NSRange(location: afterStart, length: windowLen)
                let secretMatches = secretRegex.matches(in: input, options: [], range: windowRange)
                if let secret = secretMatches.first {
                    replacements.append(Replacement(range: secret.range))
                }
            }
        }
        replacements.sort { $0.range.location > $1.range.location }

        var out = input
        for r in replacements {
            guard let swiftRange = Range(r.range, in: out) else { continue }
            out.replaceSubrange(swiftRange, with: placeholder)
        }
        return out
    }
}
