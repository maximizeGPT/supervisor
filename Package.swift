// swift-tools-version: 5.10
//
// Supervisor — a native macOS app that watches Claude Code sessions and
// intervenes when the user would have wanted to intervene.
//
// Five targets:
//   - SupervisorCore        : non-UI library; observation, triage, escalation,
//                             intervention, storage, AnthropicClient, redaction,
//                             permission probes, onboarding state machine.
//   - SupervisorUI          : SwiftUI/AppKit presentation layer. Depends on Core;
//                             Core never depends on UI.
//   - SupervisorApp         : the main @main executable. Wires Core + UI,
//                             spawns the heartbeat companion, hosts the
//                             PermissionMonitor and PermissionLostPopover.
//   - SupervisorHeartbeat   : tiny companion that writes a heartbeat file
//                             every 5s while the main app is alive.
//   - SupervisorStatusBar   : tiny menu-bar-only companion that reads the
//                             heartbeat file and reports red/amber/green
//                             health. Survives crashes of the main app.
//   - SupervisorCoreTests   : unit tests for SupervisorCore.
//
// Build-graph enforcement: Heartbeat and StatusBar depend on SupervisorCore
// but the AnthropicClient module is only invoked from SupervisorApp + the
// (future) Triage engine. Network calls cannot originate from the companions.

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
            // through Bundle.module the same way SupervisorStatusBar's
            // brand glyph does (see the StatusBar target below).
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
            dependencies: ["SupervisorCore"],
            path: "Sources/SupervisorStatusBar",
            // Brand assets: the V1 symbol ships as both raw SVG and
            // pre-rendered @1x/@2x PNG fallbacks. Asset Catalogs would
            // be cleaner but SPM does not always invoke actool depending
            // on toolchain — copying plain files into Resources/ makes
            // Bundle.module.image(forResource:) work reliably on every
            // supported macOS target. The button code marks the loaded
            // image as a template so menu-bar light/dark theming kicks in.
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
    ]
)
