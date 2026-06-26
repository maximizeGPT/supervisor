// ConfigTests.swift
//
// Path construction is the load-bearing part of Config; Keychain access
// is tested against a unique throwaway service name so the real
// `live.supervisor.api` keychain entry isn't touched by `swift test`.

import XCTest
@testable import SupervisorCore

final class ConfigTests: XCTestCase {

    // MARK: - ConfigPaths

    func testPathsRelativeToInjectedHome() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-paths-test-\(UUID().uuidString)")
        let paths = ConfigPaths(home: tmp)

        XCTAssertEqual(
            paths.appSupportDir.path,
            tmp.path + "/Library/Application Support/Supervisor"
        )
        XCTAssertEqual(
            paths.logsDir.path,
            tmp.path + "/Library/Logs/Supervisor"
        )
        XCTAssertEqual(paths.databasePath.lastPathComponent, "supervisor.sqlite")
        XCTAssertEqual(paths.heartbeatPath.lastPathComponent, "heartbeat.txt")
        XCTAssertEqual(paths.rubricPath.lastPathComponent, "rubric.yaml")
        XCTAssertEqual(paths.configPath.lastPathComponent, "config.yaml")
        XCTAssertEqual(paths.confirmationsPath.lastPathComponent, "confirmations.yaml")
        XCTAssertEqual(paths.traceLogPath.lastPathComponent, "supervisor.log")
        XCTAssertEqual(paths.claudeProjectsDir.lastPathComponent, "projects")
    }

    func testEnsureDirectoriesExistCreatesBothTrees() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-ensure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let paths = ConfigPaths(home: tmp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appSupportDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.logsDir.path))

        try paths.ensureDirectoriesExist()

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.appSupportDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.logsDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testEnsureDirectoriesIsIdempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervisor-idempotent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let paths = ConfigPaths(home: tmp)
        try paths.ensureDirectoriesExist()
        try paths.ensureDirectoriesExist()  // should not throw
        try paths.ensureDirectoriesExist()
    }

    // MARK: - APIKeyStore (in-memory)

    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryAPIKeyStore()
        XCTAssertNil(try store.read())
        try store.write("sk-ant-test-fixture-not-real")
        XCTAssertEqual(try store.read(), "sk-ant-test-fixture-not-real")
        try store.delete()
        XCTAssertNil(try store.read())
    }

    // MARK: - APIKeyStore (Keychain, throwaway service)

    func testKeychainStoreRoundTrip() throws {
        // Unique service per test invocation so concurrent runs and
        // production keys are unaffected.
        let service = "live.supervisor.api.test.\(UUID().uuidString)"
        let store = KeychainAPIKeyStore(service: service)
        defer { try? store.delete() }

        XCTAssertNil(try store.read())
        try store.write("sk-ant-throwaway")
        XCTAssertEqual(try store.read(), "sk-ant-throwaway")
        try store.write("sk-ant-overwritten")
        XCTAssertEqual(try store.read(), "sk-ant-overwritten")
        try store.delete()
        XCTAssertNil(try store.read())
    }

    // MARK: - Config

    func testConfigDefaultsMatchSpec() {
        let c = Config.defaults
        XCTAssertEqual(c.anthropicBaseURL, URL(string: "https://api.anthropic.com")!)
        XCTAssertEqual(c.triageModel, "claude-haiku-4-5-20251001")
        XCTAssertEqual(c.escalationModel, "claude-sonnet-4-6")
        XCTAssertFalse(c.axPermissionLost)
    }

    func testConfigEquatable() {
        XCTAssertEqual(Config.defaults, Config.defaults)
        var modified = Config.defaults
        modified.axPermissionLost = true
        XCTAssertNotEqual(Config.defaults, modified)
    }
}
