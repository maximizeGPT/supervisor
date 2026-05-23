// OnboardingWindowController.swift
//
// NSWindowController hosting the SwiftUI `OnboardingScene`. Sized at
// 480x360 with no resize, no minimize, no zoom — Wispr-Flow/Clicky-style
// fixed onboarding window.
//
// On `.complete` state, the controller fires `onCompletion` so the main
// app can spawn the heartbeat companion and dismiss the window.

import AppKit
import Combine
import SwiftUI
import SupervisorCore

@MainActor
public final class OnboardingWindowController: NSWindowController {

    private let vm: OnboardingViewModel
    private var cancellables: Set<AnyCancellable> = []
    private let onCompletion: (Bool) -> Void   // notifDegraded -> Void

    public init(vm: OnboardingViewModel, onCompletion: @escaping (Bool) -> Void) {
        self.vm = vm
        self.onCompletion = onCompletion

        let host = NSHostingController(rootView: OnboardingScene(vm: vm))
        let window = NSWindow(contentViewController: host)

        // v0.1.3: hide the system title bar entirely while keeping the
        // traffic-light controls and the drag-by-titlebar region.
        // Literally dropping `.titled` (Mohammed's first-pass instruction)
        // would also remove the close button and make the window
        // un-draggable — `.titled + .fullSizeContentView` with a
        // transparent + hidden title bar gives the cleaner result:
        // traffic lights float over the branded 80pt header's top-left
        // corner, and the window stays draggable through the (now
        // invisible) title bar region.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = ""

        window.setContentSize(NSSize(width: 480, height: 360))
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
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismiss() {
        window?.orderOut(nil)
    }
}
