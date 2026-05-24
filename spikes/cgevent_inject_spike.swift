// cgevent_inject_spike.swift — v0.3.0 A1.
//
// Self-verifying test for the CGEventPost keystroke-injection path.
//
// Strategy: generate a unique flag-file path, type a `touch <path>`
// command into Terminal.app via CGEventPost on the HID event tap,
// then poll for the file's existence. If the file appears within
// the timeout, the keystrokes landed AND Terminal.app executed the
// command. If it doesn't appear, the inject path failed (or landed
// in a non-Terminal frontmost window).
//
// Also reports AXIsProcessTrustedWithOptions for the calling
// process so we can correlate the AX state with success/failure.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
func main() async {
    let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
    let isTrusted = AXIsProcessTrustedWithOptions(opts)
    fputs("[spike] caller process: swift CLI\n", stderr)
    fputs("[spike] AXIsProcessTrustedWithOptions = \(isTrusted)\n", stderr)
    fputs("[spike] PID = \(ProcessInfo.processInfo.processIdentifier)\n", stderr)

    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let flagPath = "/tmp/cgevent-spike-\(stamp).flag"
    fputs("[spike] flag path: \(flagPath)\n", stderr)
    fputs("[spike] will type: touch \(flagPath)\n", stderr)

    // Activate Terminal.app frontmost.
    fputs("[spike] activating Terminal.app...\n", stderr)
    let term = NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == "com.apple.Terminal"
    }
    if let term {
        term.activate(options: [])
    } else {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    try? await Task.sleep(nanoseconds: 1_500_000_000)

    // Type the touch command.
    fputs("[spike] typing command...\n", stderr)
    let text = "touch \(flagPath)"
    let source = CGEventSource(stateID: .hidSystemState)
    for ch in text.unicodeScalars {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            fputs("[spike] FAIL: couldn't create keyboard event\n", stderr)
            return
        }
        var c = UniChar(ch.value)
        keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
        keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
        keyDown.post(tap: .cghidEventTap)
        usleep(15_000)
        keyUp.post(tap: .cghidEventTap)
        usleep(5_000)
    }

    // Press Return — virtualKey 36.
    fputs("[spike] sending Return...\n", stderr)
    if let downRet = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
       let upRet = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) {
        downRet.post(tap: .cghidEventTap)
        usleep(15_000)
        upRet.post(tap: .cghidEventTap)
    }

    // Poll for the flag file. 3s timeout (Terminal needs to execute
    // the typed command, which is just a touch — should be ~10ms).
    fputs("[spike] polling for flag file...\n", stderr)
    let deadline = Date().addingTimeInterval(3.0)
    var landed = false
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: flagPath) {
            landed = true
            break
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    if landed {
        fputs("[spike] ✅ PASS: flag file appeared at \(flagPath)\n", stderr)
        fputs("[spike] CGEventPost keystroke injection works.\n", stderr)
        fputs("[spike] AX state was: \(isTrusted ? "GRANTED" : "REVOKED")\n", stderr)
        try? FileManager.default.removeItem(atPath: flagPath)
        exit(0)
    } else {
        fputs("[spike] ❌ FAIL: flag file did NOT appear within 3s\n", stderr)
        fputs("[spike] Either keystrokes were dropped, landed in a non-Terminal window, or Terminal didn't execute the command.\n", stderr)
        exit(1)
    }
}

await main()
