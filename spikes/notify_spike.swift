// notify_spike.swift — Phase 0 spike for Supervisor v0.1.0.
//
// Probes UNUserNotificationCenter behavior for an unsigned, ad-hoc-built
// macOS app. Answers: does requestAuthorization() resolve at all? Does
// scheduling a notification succeed? Are delivered notifications visible
// in the notification center?
//
// Built into a minimal .app bundle by build_notify_app.sh so it has a
// CFBundleIdentifier (UNUserNotificationCenter refuses non-bundled
// executables).

import Foundation
import UserNotifications
import AppKit

setbuf(stdout, nil)

let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

func log(_ msg: String) {
    print("[\(formatter.string(from: Date()))] \(msg)")
}

log("starting notify_spike")
log("bundle.bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "(nil)")")
log("bundle.bundlePath=\(Bundle.main.bundlePath)")
log("process.processName=\(ProcessInfo.processInfo.processName)")

let center = UNUserNotificationCenter.current()
log("UNUserNotificationCenter.current() = \(center)")

// Step 1: query current authorization status (does not prompt).
center.getNotificationSettings { settings in
    log("auth status (pre-request) = \(settings.authorizationStatus.rawValue) (\(authStatusName(settings.authorizationStatus)))")
    log("alert setting = \(settings.alertSetting.rawValue) (\(settingName(settings.alertSetting)))")
    log("notification center setting = \(settings.notificationCenterSetting.rawValue)")
    log("sound setting = \(settings.soundSetting.rawValue)")
    log("badge setting = \(settings.badgeSetting.rawValue)")

    // Step 2: request authorization. Will prompt the user the first time;
    // subsequent calls return the persisted decision.
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
        if let error = error {
            log("requestAuthorization ERROR: \(error)")
        } else {
            log("requestAuthorization granted=\(granted)")
        }

        // Step 3: re-query settings.
        center.getNotificationSettings { settings in
            log("auth status (post-request) = \(settings.authorizationStatus.rawValue) (\(authStatusName(settings.authorizationStatus)))")

            // Step 4: attempt to schedule a notification regardless of grant.
            let content = UNMutableNotificationContent()
            content.title = "Supervisor spike"
            content.body = "If you see this banner, unsigned UNUserNotificationCenter works."
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(
                identifier: "supervisor.spike.\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            center.add(request) { error in
                if let error = error {
                    log("center.add ERROR: \(error)")
                } else {
                    log("center.add succeeded — notification scheduled for 1s from now")
                }

                // Step 5: wait a bit to let the notification fire, then read
                // delivered + pending lists.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    center.getPendingNotificationRequests { pending in
                        log("pending notifications count = \(pending.count)")
                        for req in pending {
                            log("  pending: \(req.identifier)")
                        }
                        center.getDeliveredNotifications { delivered in
                            log("delivered notifications count = \(delivered.count)")
                            for n in delivered {
                                log("  delivered: \(n.request.identifier) at \(n.date)")
                            }
                            log("notify_spike done")
                            exit(0)
                        }
                    }
                }
            }
        }
    }
}

func authStatusName(_ s: UNAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .denied:        return "denied"
    case .authorized:    return "authorized"
    case .provisional:   return "provisional"
    case .ephemeral:     return "ephemeral"
    @unknown default:    return "unknown(\(s.rawValue))"
    }
}

func settingName(_ s: UNNotificationSetting) -> String {
    switch s {
    case .notSupported: return "notSupported"
    case .disabled:     return "disabled"
    case .enabled:      return "enabled"
    @unknown default:   return "unknown(\(s.rawValue))"
    }
}

// Keep the app alive while async work runs. AppKit's NSApplication ensures
// the run loop has the right modes for UNUserNotificationCenter delegation.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // No dock icon for the spike.
app.run()
