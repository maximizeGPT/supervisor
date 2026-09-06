// ConfigWatcher.swift
//
// FSEvents-based file watcher for config.yaml. When the file changes,
// re-reads and notifies subscribers via a callback. Uses
// DispatchSource.makeFileSystemObjectSource so it fires on write,
// rename, and delete (the last two catch atomic-save editors like
// vim that write-to-tmp then rename).
//
// v0.1.x Issue #3: live-reload user config.

import Foundation

@MainActor
public final class ConfigWatcher {

    public typealias OnChange = @MainActor (UserConfig) -> Void

    private let configPath: URL
    private let trace: TraceLog
    private let onChange: OnChange
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    public init(
        configPath: URL,
        trace: TraceLog = .shared,
        onChange: @escaping OnChange
    ) {
        self.configPath = configPath
        self.trace = trace
        self.onChange = onChange
    }

    public func start() {
        stop()
        startWatching()
    }

    public func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func startWatching() {
        let path = configPath.path

        // Ensure the parent directory exists so the file descriptor
        // is valid even if config.yaml doesn't exist yet. We watch
        // the directory in that case and re-try when it appears.
        let dirPath = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dirPath,
            withIntermediateDirectories: true
        )

        // If the file exists, watch the file itself. If not, watch
        // the parent directory for new-file creation.
        let watchPath: String
        let watchingDir: Bool
        if FileManager.default.fileExists(atPath: path) {
            watchPath = path
            watchingDir = false
        } else {
            watchPath = dirPath
            watchingDir = true
        }

        fileDescriptor = Darwin.open(watchPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            trace.emit("config", "watcher failed to open \(watchPath)")
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        src.setEventHandler { [weak self] in
            // The source is scheduled on the main queue, so main-actor
            // state is reachable synchronously here — and it must be: the
            // event mask is per-delivery, so it is read NOW, not after an
            // async hop that could coalesce or drop it.
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = self.source?.data ?? []
                self.handleEvent(event, watchingDir: watchingDir)
            }
        }

        src.setCancelHandler { [fd = fileDescriptor] in
            if fd >= 0 { Darwin.close(fd) }
        }

        // Don't double-close in stop() since the cancel handler owns it now.
        self.fileDescriptor = -1
        self.source = src
        src.resume()

        trace.emit("config", "watcher started on \(watchPath) (dir=\(watchingDir))")
    }

    /// One file-system event on the watched path. Always reloads by PATH
    /// (never through the possibly-dead descriptor), then re-arms when the
    /// inode went away under us.
    private func handleEvent(_ event: DispatchSource.FileSystemEvent, watchingDir: Bool) {
        let path = configPath.path
        if watchingDir {
            // Re-check if config.yaml appeared; restart to watch the file
            // directly.
            if FileManager.default.fileExists(atPath: path) {
                stop()
                let config = UserConfig.load(from: configPath)
                onChange(config)
                startWatching()
            }
            return
        }
        let config = UserConfig.load(from: configPath)
        trace.emit("config", "reloaded \(config.additionalHostApps.count) additional host apps")
        onChange(config)
        // Atomic saves (vim-style editors, and RemoteNotifyConfigWriter's
        // own temp+rename write) replace the file's INODE. The descriptor
        // this source watches still points at the old, now-deleted inode:
        // without re-arming, this delete/rename event is the last one the
        // watcher would ever see and every later owner edit goes silent.
        // Re-open by path and re-arm.
        if event.contains(.delete) || event.contains(.rename) {
            trace.emit("config", "watched inode replaced (atomic save) — re-arming on the new file")
            stop()
            startWatching()
        }
    }
}
