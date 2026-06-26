// PermissionMonitor.swift
//
// Polls the PermissionChecker every ~3s and surfaces transitions (revoked,
// regranted) as published events the main app can react to.
//
// macOS has no built-in notification for AX grant changes — polling is
// the only path. Notification permission has similar limits. 3s is a
// conservative cadence: light on CPU, fast enough that the user doesn't
// notice the delay when they grant a permission in System Settings.
//
// The main app subscribes to `events` to drive the PermissionLostPopover
// lifecycle. The monitor itself is UI-free.

import Combine
import Foundation

public enum PermissionEvent: Sendable, Equatable {
    case axRevoked
    case axRegranted
    case notificationsRevoked
    case notificationsRegranted
}

@MainActor
public final class PermissionMonitor: ObservableObject {

    @Published public private(set) var lastSnapshot: PermissionSnapshot?

    /// Publishes a stream of transition events. Subscribers see only
    /// transitions, not every poll — the popover should fire on revoke,
    /// not on every confirmation that "yes, still revoked."
    public let events: PassthroughSubject<PermissionEvent, Never> = .init()

    private let checker: any PermissionChecker
    private let trace: TraceLog
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    public init(
        checker: any PermissionChecker,
        interval: TimeInterval = 3.0,
        trace: TraceLog = .shared
    ) {
        self.checker = checker
        self.interval = interval
        self.trace = trace
    }

    public func start() {
        guard task == nil else { return }
        trace.emit("permmonitor", "start interval=\(interval)s")
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        trace.emit("permmonitor", "stop")
    }

    /// One-shot probe. Useful from `NSApplication.didBecomeActive` to
    /// shorten the recovery latency after the user touches System Settings.
    public func probeNow() async {
        await checkAndEmit()
    }

    private func loop() async {
        while !Task.isCancelled {
            await checkAndEmit()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func checkAndEmit() async {
        let snap = await checker.snapshot()
        defer { lastSnapshot = snap }

        guard let prev = lastSnapshot else {
            // First poll — establish baseline, don't emit events for it.
            trace.emit("permmonitor", "baseline ax=\(snap.ax) notif=\(snap.notifications)")
            return
        }

        if prev.ax && !snap.ax {
            trace.emit("permmonitor", "AX revoked")
            events.send(.axRevoked)
        } else if !prev.ax && snap.ax {
            trace.emit("permmonitor", "AX regranted")
            events.send(.axRegranted)
        }

        // Notifications: revoke = transition into .denied; regrant = back
        // out of .denied into anything that lets banners through.
        let prevNotifGood = (prev.notifications != .denied && prev.notifications != .notDetermined)
        let curNotifGood  = (snap.notifications != .denied && snap.notifications != .notDetermined)
        if prevNotifGood && !curNotifGood {
            trace.emit("permmonitor", "notif revoked: \(prev.notifications) -> \(snap.notifications)")
            events.send(.notificationsRevoked)
        } else if !prevNotifGood && curNotifGood {
            trace.emit("permmonitor", "notif regranted: \(prev.notifications) -> \(snap.notifications)")
            events.send(.notificationsRegranted)
        }
    }
}
