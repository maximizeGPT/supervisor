// E2EIsolationSeamTests.swift
//
// The seams the true-new-user E2E harness stands on: SUPERVISOR_HOME
// (ConfigPaths.resolvedHome) and SUPERVISOR_KEYCHAIN_PREFIX
// (LLMProvider.keychainServiceBase), plus FakeClaudeCLI's --script
// restamping (ScriptRestamper).
//
// All assertions run against the injectable-environment variants, never
// setenv: ProcessInfo caches its environment snapshot on first access, so
// an in-test setenv is invisible whenever any earlier test touched the
// environment — the flake shape we refuse to ship.

import FakeClaudeScript
import XCTest
@testable import SupervisorCore

final class E2EIsolationSeamTests: XCTestCase {

    // MARK: - SUPERVISOR_HOME → ConfigPaths.resolvedHome

    func testResolvedHomeHonorsOverride() {
        let home = ConfigPaths.resolvedHome(environment: ["SUPERVISOR_HOME": "/tmp/e2e-fake-home"])
        XCTAssertEqual(home.path, "/tmp/e2e-fake-home")
    }

    func testResolvedHomeFallsBackToRealHomeWhenUnsetOrEmpty() {
        let real = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(ConfigPaths.resolvedHome(environment: [:]), real)
        // Empty string must not become a relative-root URL; it means "unset".
        XCTAssertEqual(ConfigPaths.resolvedHome(environment: ["SUPERVISOR_HOME": ""]), real)
    }

    func testConfigPathsTreeHangsOffOverriddenHome() {
        let home = ConfigPaths.resolvedHome(environment: ["SUPERVISOR_HOME": "/tmp/e2e-fake-home"])
        let paths = ConfigPaths(home: home)
        XCTAssertEqual(
            paths.appSupportDir.path,
            "/tmp/e2e-fake-home/Library/Application Support/Supervisor"
        )
        XCTAssertEqual(paths.claudeProjectsDir.path, "/tmp/e2e-fake-home/.claude/projects")
        XCTAssertEqual(paths.pidfilePath.path.hasPrefix("/tmp/e2e-fake-home/"), true)
    }

    /// The default init and the static resolver must agree — this is the
    /// contract the app relies on (`ConfigPaths()` at startup IS the seam).
    func testDefaultInitUsesResolvedHome() {
        XCTAssertEqual(ConfigPaths().home, ConfigPaths.resolvedHome)
    }

    // MARK: - SUPERVISOR_KEYCHAIN_PREFIX → keychain service names

    func testKeychainServiceBaseHonorsPrefix() {
        XCTAssertEqual(
            LLMProvider.keychainServiceBase(environment: ["SUPERVISOR_KEYCHAIN_PREFIX": "test.supervisor.e2e"]),
            "test.supervisor.e2e"
        )
        XCTAssertEqual(LLMProvider.keychainServiceBase(environment: [:]), "live.supervisor.api")
        // Empty means unset, same rule as SUPERVISOR_HOME.
        XCTAssertEqual(
            LLMProvider.keychainServiceBase(environment: ["SUPERVISOR_KEYCHAIN_PREFIX": ""]),
            "live.supervisor.api"
        )
    }

    func testKeychainServiceComposesBasePlusProviderSuffix() {
        XCTAssertEqual(LLMProvider.anthropic.keychainService(base: "test.supervisor.e2e"), "test.supervisor.e2e.anthropic")
        XCTAssertEqual(LLMProvider.deepseek.keychainService(base: "test.supervisor.e2e"), "test.supervisor.e2e.deepseek")
        XCTAssertEqual(LLMProvider.qwenHF.keychainService(base: "live.supervisor.api"), "live.supervisor.api.qwenhf")
        // Every provider must be namespaced under the base — a provider whose
        // service escaped the prefix would silently write live items from a
        // test instance.
        for provider in LLMProvider.allCases {
            XCTAssertTrue(
                provider.keychainService(base: "test.x").hasPrefix("test.x."),
                "\(provider) escapes the keychain base"
            )
        }
    }

    /// The production defaults must be byte-identical to what v0.2.0 shipped
    /// (existing users' keys live under these exact names).
    func testDefaultServiceNamesUnchangedFromV020() {
        XCTAssertEqual(LLMProvider.anthropic.keychainService(base: "live.supervisor.api"), "live.supervisor.api.anthropic")
        XCTAssertEqual(LLMProvider.moonshot.keychainService(base: "live.supervisor.api"), "live.supervisor.api.moonshot")
        XCTAssertEqual(LLMProvider.minimax.keychainService(base: "live.supervisor.api"), "live.supervisor.api.minimax")
        XCTAssertEqual(LLMProvider.openrouter.keychainService(base: "live.supervisor.api"), "live.supervisor.api.openrouter")
    }

    /// Live computed properties must agree with the injectable variants under
    /// THIS process's environment, whatever it is — the app calls the
    /// computed ones, the tests verify the injectable ones, and this pins
    /// them together. Also: the legacy service (migrateLegacyKeyIfPresent's
    /// DELETE target) must be the bare base, so a prefixed test run deletes
    /// only test items.
    func testComputedPropertiesTrackProcessEnvironment() {
        let env = ProcessInfo.processInfo.environment
        XCTAssertEqual(LLMProvider.keychainServiceBase, LLMProvider.keychainServiceBase(environment: env))
        XCTAssertEqual(
            LLMProvider.deepseek.keychainService,
            LLMProvider.deepseek.keychainService(base: LLMProvider.keychainServiceBase)
        )
        XCTAssertEqual(LLMProvider.legacyAnthropicKeychainService, LLMProvider.keychainServiceBase)
        XCTAssertEqual(KeychainAPIKeyStore.defaultService, LLMProvider.keychainServiceBase)
    }

    // MARK: - FakeClaudeCLI --script restamping

    func testRestampRewritesTimestampToNow() throws {
        let line = #"{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","sessionId":"s","message":{"role":"user","content":"hi"}}"#
        let now = Date()
        let out = ScriptRestamper.restampLine(line, now: now)

        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        )
        let stamped = try XCTUnwrap(obj["timestamp"] as? String)
        let parsed = try XCTUnwrap(ScriptRestamper.isoFormatter.date(from: stamped))
        // Millisecond precision: the formatter truncates fractional seconds.
        XCTAssertEqual(parsed.timeIntervalSince(now), 0, accuracy: 0.01)
        // The rest of the event must ride through unchanged.
        XCTAssertEqual(obj["type"] as? String, "user")
        XCTAssertEqual((obj["message"] as? [String: Any])?["content"] as? String, "hi")
    }

    func testRestampSubstitutesPlaceholders() throws {
        let line = #"{"type":"queue-operation","timestamp":"2026-01-01T00:00:00.000Z","sessionId":"__SESSION_ID__","cwd":"__CWD__"}"#
        let out = ScriptRestamper.restampLine(
            line, now: Date(), cwd: "/tmp/e2e/project", sessionId: "e2e-abc"
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["cwd"] as? String, "/tmp/e2e/project")
        XCTAssertEqual(obj["sessionId"] as? String, "e2e-abc")
    }

    func testRestampLeavesTimestampFreeLinesAlone() {
        // No timestamp field: no restamp — but placeholder substitution still
        // applies (it is textual, pre-parse).
        let line = #"{"type":"weird","sessionId":"__SESSION_ID__"}"#
        let out = ScriptRestamper.restampLine(line, now: Date(), sessionId: "x")
        XCTAssertTrue(out.contains(#""sessionId":"x""#) || out.contains(#""sessionId" : "x""#))
        XCTAssertFalse(out.contains("timestamp"))
    }

    func testRestampPassesNonJSONThrough() {
        // Malformed fixture lines flow through (the tailer skips them);
        // eating them would hide fixture bugs.
        let line = "not json at all __CWD__"
        let out = ScriptRestamper.restampLine(line, now: Date(), cwd: "/tmp/x")
        XCTAssertEqual(out, "not json at all /tmp/x")
    }

    func testRestampedEventIsFreshEnoughForTriage() throws {
        // The reason the mode exists: TriageEngine discards events older than
        // ~120s. A fixture authored "in the past" must come out inside that
        // window.
        let line = #"{"type":"assistant","timestamp":"2020-06-01T12:00:00.000Z","sessionId":"s"}"#
        let out = ScriptRestamper.restampLine(line, now: Date())
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
        )
        let stamped = try XCTUnwrap(obj["timestamp"] as? String)
        let parsed = try XCTUnwrap(ScriptRestamper.isoFormatter.date(from: stamped))
        XCTAssertLessThan(abs(parsed.timeIntervalSinceNow), 120)
    }
}
