// OnboardingWindowController.swift
//
// NSWindowController hosting the SwiftUI `OnboardingScene`. Sized at
// 480x420 with no resize, no minimize, no zoom, Wispr-Flow/Clicky-style
// fixed onboarding window. Height was 360pt in v0.1.3 but at that size
// the AX step body + Notif-denied state body BOTH overflowed the 224pt
// content band, eating into the 56pt footer and clipping the
// "Skip"/"Open System Settings" buttons. v0.1.6.3 grows the window to
// 420pt (content band: 284pt, +60pt headroom) to fit the body text
// without trimming the (legitimately useful) escape-hatch copy.
//
// On `.complete` state, the controller fires `onCompletion` so the main
// app can spawn the heartbeat companion and dismiss the window.
//
// One instance does NOT get that window on screen: an isolated instance (an
// E2E scenario, resolving its own SUPERVISOR_HOME). It gets a real window,
// because the harness drives onboarding over the Accessibility API, placed
// off every screen and never activated. See `presentsOnScreen`.

import AppKit
import Combine
import SwiftUI
import SupervisorCore

/// The onboarding window, with one behavior NSWindow does not offer: it can be
/// placed genuinely off screen.
///
/// AppKit nudges a titled window back until its title bar is reachable
/// (`constrainFrameRect`) every time the window is ordered in, so
/// `setFrameOrigin(farAway)` alone would bounce an isolated instance's window
/// straight back onto the owner's screen. The override is armed ONLY for a
/// suppressed instance; the owner's own window keeps AppKit's
/// keep-it-reachable behavior exactly as it was.
final class OnboardingWindow: NSWindow {
    var allowsOffScreenPlacement = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsOffScreenPlacement ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

@MainActor
public final class OnboardingWindowController: NSWindowController {

    private let vm: OnboardingViewModel
    private var cancellables: Set<AnyCancellable> = []
    private let onCompletion: (Bool) -> Void   // notifDegraded -> Void

    /// Whether this instance may put the onboarding window on the user's
    /// screen. False for any instance resolving a non-default
    /// `SUPERVISOR_HOME`, which today means an E2E scenario — s03 launches
    /// against a virgin fake home precisely to land in onboarding, and until
    /// this gate it painted a 480x420 window over the owner's desktop and
    /// stole his focus with `NSApp.activate`. Same bug as the stacked hover
    /// pills, bigger window.
    ///
    /// The suppressed instance still builds a REAL window and orders it in,
    /// because s03 drives onboarding through the Accessibility API and AX only
    /// reports windows the app actually has. What it does not get is a
    /// position on any screen, or the activation that would pull the owner's
    /// keyboard focus into it.
    public let presentsOnScreen: Bool

    /// Far outside any plausible display arrangement, in both axes, so the
    /// window is off screen no matter how many displays are attached or where
    /// they sit relative to each other. AX positions are reported in the same
    /// coordinate space, so a scenario can also assert on this if it wants to.
    static let offScreenOrigin = NSPoint(x: -1_000_000, y: -1_000_000)

    public init(
        vm: OnboardingViewModel,
        presentsOnScreen: Bool = ConfigPaths.isRealUserHome,
        onCompletion: @escaping (Bool) -> Void
    ) {
        self.vm = vm
        self.presentsOnScreen = presentsOnScreen
        self.onCompletion = onCompletion

        let host = NSHostingController(rootView: OnboardingScene(vm: vm))
        let window = OnboardingWindow(contentViewController: host)
        window.allowsOffScreenPlacement = !presentsOnScreen

        // v0.1.3: hide the system title bar entirely while keeping the
        // traffic-light controls and the drag-by-titlebar region.
        // Literally dropping `.titled` (Mohammed's first-pass instruction)
        // would also remove the close button and make the window
        // un-draggable, `.titled + .fullSizeContentView` with a
        // transparent + hidden title bar gives the cleaner result:
        // traffic lights float over the branded 80pt header's top-left
        // corner, and the window stays draggable through the (now
        // invisible) title bar region.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = ""

        window.setContentSize(NSSize(width: 480, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal

        super.init(window: window)

        // Bridge .complete state → completion callback.
        vm.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .complete(let degraded) = state {
                    self?.onCompletion(degraded)
                }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    public func present() {
        guard presentsOnScreen else {
            presentOffScreen()
            return
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The isolated-instance path: a real, ordered-in window that no screen
    /// contains and no user ever sees.
    ///
    /// Not "skip the window entirely": s03 walks the onboarding steps over AX
    /// (`--pid <app> tree`, `press`, `set`), and AX enumerates the app's
    /// windows, so an instance with no window is an instance the scenario
    /// cannot drive at all. Off screen keeps the scenario and takes the pixels
    /// away, which is the whole ask.
    ///
    /// `orderFront`, not `makeKeyAndOrderFront` + `NSApp.activate`: ordering is
    /// what puts the window in the list AX reads, activating is what would
    /// yank the owner's focus out of whatever he is typing in.
    private func presentOffScreen() {
        window?.setFrameOrigin(Self.offScreenOrigin)
        window?.orderFront(nil)
    }

    public func dismiss() {
        window?.orderOut(nil)
    }
}
