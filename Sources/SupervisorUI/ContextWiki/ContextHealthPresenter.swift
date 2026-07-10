// ContextHealthPresenter.swift — opens (and reuses) the Context Health window.
//
// Shared by every entry point that names the feature: the status-bar menu item,
// the expanded-panel Context Health line, and the one earned notification. Each
// process (main app / status bar) holds its own @MainActor singleton and its own
// window; all doors name the feature identically and open the one window, so it
// reads as three doors to one room.

import AppKit
import Foundation
import SupervisorCore

@MainActor
public final class ContextHealthPresenter {

    public static let shared = ContextHealthPresenter()

    private var controller: ContextWikiWindowController?

    public init() {}

    /// Open the Context Health window for `root`, reusing an already-open window
    /// (bring it forward) instead of stacking a second one.
    public func present(root: URL, store: ContextAuditStore? = nil) {
        if let controller, controller.window?.isVisible == true {
            controller.present()
            return
        }
        let vm = ContextWikiViewModel(root: root, store: store)
        let controller = ContextWikiWindowController(vm: vm)
        self.controller = controller
        controller.present()
    }
}
