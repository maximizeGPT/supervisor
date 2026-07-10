// swift-tools-version: 5.10
//
// Supervisor — a native macOS app that watches Claude Code sessions and
// intervenes when the user would have wanted to intervene.
//
// Targets:
//   - SupervisorCore        : non-UI library; observation, triage, escalation,
//                             intervention, storage, AnthropicClient, redaction,
//                             permission probes, onboarding state machine.
//   - SupervisorUI          : SwiftUI/AppKit presentation layer. Depends on Core;
//                             Core never depends on UI.
//   - SupervisorApp         : the main @main executable. Wires Core + UI,
//                             spawns the heartbeat + status-bar companions,
//                             hosts the PermissionMonitor and
//                             PermissionLostPopover.
//   - SupervisorHeartbeat   : tiny companion that writes a heartbeat file
//                             every 5s while the main app is alive.
//   - SupervisorStatusBar   : tiny menu-bar-only companion that reads the
//                             heartbeat file and reports red/amber/green
//                             health. Survives crashes of the main app.
//   - SupervisorCoreTests   : unit tests for SupervisorCore.
//
// The menu-bar status item is a SEPARATE process on purpose. A v0.3.0 RC
// briefly folded it into SupervisorApp, but an in-process NSStatusItem dies
// with the app: a crash makes the icon vanish (instead of turning red) and a
// hung engine keeps a static green icon forever. Out-of-process +
// heartbeat-driven is the only design where a dead/hung supervisor honestly
// shows red/amber, so the companion was restored.
//
// Build-graph enforcement: Heartbeat and StatusBar depend on SupervisorCore
// but the AnthropicClient module is only invoked from SupervisorApp + the
// Triage engine. Network calls cannot originate from the companions.

import PackageDescription

let package = Package(
    name: "Supervisor",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SupervisorCore", targets: ["SupervisorCore"]),
        .library(name: "SupervisorUI", targets: ["SupervisorUI"]),
        .executable(name: "Supervisor", targets: ["SupervisorApp"]),
        .executable(name: "SupervisorHeartbeat", targets: ["SupervisorHeartbeat"]),
        .executable(name: "SupervisorStatusBar", targets: ["SupervisorStatusBar"]),
        // Dev/preview harness for the Context Health window (Context Wiki UI).
        // Opens the real SwiftUI window against a live audit so the view can be
        // rendered + screenshotted without launching the whole app. Not shipped.
        .executable(name: "ContextWikiPreview", targets: ["ContextWikiPreview"]),
    ],
    dependencies: [
        // Only two external deps in v0.1.0. Yams (YAML) lands in v0.1.4 with
        // the RubricLoader — no point carrying an unused dep across three
        // minor versions.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
    ],
    targets: [
        .target(
            name: "SupervisorCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
            ],
            path: "Sources/SupervisorCore"
        ),
        .target(
            name: "SupervisorUI",
            dependencies: ["SupervisorCore"],
            path: "Sources/SupervisorUI",
            // v0.1.3: onboarding wordmark + future brand assets ship
            // through Bundle.module's Resources/ processing.
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "SupervisorApp",
            dependencies: ["SupervisorCore", "SupervisorUI"],
            path: "Sources/SupervisorApp"
        ),
        .executableTarget(
            name: "SupervisorHeartbeat",
            dependencies: ["SupervisorCore"],
            path: "Sources/SupervisorHeartbeat"
        ),
        .executableTarget(
            name: "SupervisorStatusBar",
            // SupervisorUI added in the Context Wiki feature: the status-bar menu
            // hosts the on-demand "Context Health" window. SwiftUI is constructed
            // only when the user opens it, so the always-present icon stays light.
            dependencies: ["SupervisorCore", "SupervisorUI"],
            path: "Sources/SupervisorStatusBar",
            // Brand assets: the V1 symbol ships as raw SVG + pre-rendered
            // @1x/@2x PNG fallbacks. Copying plain files into Resources/ makes
            // Bundle.module.image(forResource:) work reliably across toolchains
            // (SPM does not always invoke actool for Asset Catalogs). The button
            // code marks the loaded image as a template so menu-bar light/dark
            // theming kicks in; a missing asset falls back to an SF Symbol.
            resources: [.process("Resources")]
        ),
        // Dev helper: writes the Anthropic key into the same Keychain
        // entry Supervisor reads, via KeychainAccess (same ACL identity).
        // Not built into release bundles; used during Checkpoint C smoke
        // and any time a developer needs to bypass onboarding.
        .executableTarget(
            name: "SupervisorDevTools",
            dependencies: ["SupervisorCore"],
            path: "Sources/SupervisorDevTools"
        ),
        // Context Health window preview harness (see product note above).
        .executableTarget(
            name: "ContextWikiPreview",
            dependencies: ["SupervisorCore", "SupervisorUI"],
            path: "Sources/ContextWikiPreview"
        ),
        // v0.1.4: fake-Claude harness for ProcessLocator tests. Writes
        // realistic-shaped JSONL events to a target path at a configurable
        // cadence, holds the fd open (or simulates the bad case where
        // Claude open-writes-closes), and records its PID to a sidecar
        // file so tests can verify the locator returned the right PID.
        // Foundation-only, no SupervisorCore dependency — keeps the
        // harness independent of the code under test.
        .executableTarget(
            name: "FakeClaudeCLI",
            dependencies: [],
            path: "Sources/FakeClaudeCLI"
        ),
        .testTarget(
            name: "SupervisorCoreTests",
            dependencies: ["SupervisorCore"],
            path: "Tests/SupervisorCoreTests"
        ),
        // v0.1.6.1: minimal UI test target so the host-app set has a
        // regression test (com.anthropic.claudefordesktop landing here
        // matters — it's the bundle ID that lets the hover show when the
        // user has the Claude desktop app frontmost). Future UI tests
        // land here too.
        .testTarget(
            name: "SupervisorUITests",
            dependencies: ["SupervisorUI"],
            path: "Tests/SupervisorUITests"
        ),
    ]
)
