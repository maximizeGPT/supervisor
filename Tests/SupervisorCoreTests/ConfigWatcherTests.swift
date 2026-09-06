// ConfigWatcherTests.swift
//
// The live-reload watcher's one hard failure mode: an atomic (temp+rename)
// save replaces the config file's INODE, and a kqueue-backed source keeps
// watching the old, deleted one — the rename event is then the last event
// it ever sees and every later edit goes silent. Since
// RemoteNotifyConfigWriter itself now writes atomically (crash-safe over
// the owner's whole config), the watcher must survive the swap by
// re-arming on the new file. Exercised here with the REAL writer, so the
// test is the panel-toggle round trip minus the view model.

import XCTest
@testable import SupervisorCore

@MainActor
final class ConfigWatcherTests: XCTestCase {

    private var dir: URL!
    private var configPath: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-watcher-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configPath = dir.appendingPathComponent("config.yaml")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func scratchTrace() -> TraceLog {
        TraceLog(path: dir.appendingPathComponent("trace.log"))
    }

    /// Spin the main actor until `condition` holds (the DispatchSource is
    /// scheduled on the main queue, which turns while this suspends).
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        _ message: String = "",
        timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(condition(), message)
    }

    func testWatcherSurvivesRenameBasedAtomicWrites() async throws {
        // Seed a plain file so the watcher arms on the FILE (not the dir).
        try "remote_notify:\n  enabled: false\n".write(to: configPath, atomically: false, encoding: .utf8)

        final class Seen { var values: [Bool] = [] }
        let seen = Seen()
        let watcher = ConfigWatcher(configPath: configPath, trace: scratchTrace()) { config in
            seen.values.append(config.remoteNotifyEnabled)
        }
        watcher.start()
        defer { watcher.stop() }

        // First write through the real (atomic, inode-replacing) writer.
        try RemoteNotifyConfigWriter.write(values: .init(enabled: true, detail: .minimal), to: configPath)
        await waitUntil(seen.values.contains(true), "the rename-based write must reload")

        // The write that proves re-arming: a watcher still holding the OLD
        // inode's descriptor would never see this one.
        let countAfterFirst = seen.values.count
        try RemoteNotifyConfigWriter.write(values: .init(enabled: false, detail: .full), to: configPath)
        await waitUntil(
            seen.values.count > countAfterFirst && seen.values.last == false,
            "a second atomic save after the inode swap must still live-reload"
        )
        let reread = UserConfig.load(from: configPath)
        XCTAssertFalse(reread.remoteNotifyEnabled)
        XCTAssertEqual(reread.remoteNotifyDetail, .full)
    }

    func testWatcherStillSeesInPlaceWrites() async throws {
        // The ordinary non-replacing write path (echo >> style edits) must
        // keep working after the event-handling rework.
        try "remote_notify:\n  enabled: false\n".write(to: configPath, atomically: false, encoding: .utf8)

        final class Seen { var values: [Bool] = [] }
        let seen = Seen()
        let watcher = ConfigWatcher(configPath: configPath, trace: scratchTrace()) { config in
            seen.values.append(config.remoteNotifyEnabled)
        }
        watcher.start()
        defer { watcher.stop() }

        let handle = try FileHandle(forWritingTo: configPath)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("remote_notify:\n  enabled: true\n".utf8))
        try handle.close()
        await waitUntil(seen.values.contains(true), "an in-place write must still reload")
    }
}
