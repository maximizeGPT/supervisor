// ActionFlashTests.swift
//
// Regression coverage for the action flash that "kept getting shipped but
// was never seen." The bug class: the flash code existed but the thing the
// rendered HoverView actually animates on (vm.actionFlash) and the label it
// renders (vm.plainLabel) were not both driven by an action event.
//
// HoverView's body binds to exactly these two published properties:
//   - vm.actionFlash  -> the border-glow .overlay + .scaleEffect animation
//     (HoverView.swift lines ~65-70)
//   - vm.plainLabel   -> the headline Text (HoverView.swift line ~36)
// So asserting an action event sets BOTH is asserting the rendered view's
// flash is actually triggered by the event, not merely that a row was added
// to the RECENT ACTIONS log (recentActions).

import XCTest
@testable import SupervisorCore
@testable import SupervisorUI

@MainActor
final class ActionFlashTests: XCTestCase {

    private func makeVM() -> HoverViewModel {
        let trace = TraceLog(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("flash-test-\(UUID()).log"))
        let bus = EventBus(trace: trace)
        return HoverViewModel(bus: bus, trace: trace)
    }

    /// The core assertion: a substantial action event lights actionFlash
    /// (the animation driver) AND surfaces the plain-language label the
    /// hover renders — not just a RECENT ACTIONS row.
    func testActionEventTriggersFlashAndLabel() {
        let vm = makeVM()
        XCTAssertFalse(vm.actionFlash, "flash must start off")

        vm.recordAction(action: .pause, description: "Paused Claude Code. Needs your attention.")

        XCTAssertTrue(vm.actionFlash,
            "an action event must trigger actionFlash (the property HoverView animates on)")
        XCTAssertEqual(vm.plainLabel, "Paused Claude Code. Needs your attention.",
            "the action's plain-language label must be surfaced on the hover, not just logged")
        // And it must ALSO be logged — but that is separate from the flash.
        XCTAssertEqual(vm.recentActions.first?.action, .pause)
    }

    /// The HoverView is constructed against the flashing VM — a compile-time
    /// guarantee the rendered view binds to this exact view model instance.
    func testRenderedHoverViewBindsTheFlashingViewModel() {
        let vm = makeVM()
        vm.recordAction(action: .continue, description: "Sent Claude Code its next task")
        let view = HoverView(vm: vm)
        XCTAssertNotNil(view.body)
        XCTAssertTrue(vm.actionFlash)
    }

    /// Plain notify is informational, not a substantial action: no flash,
    /// no log row.
    func testNotifyDoesNotFlash() {
        let vm = makeVM()
        vm.recordAction(action: .notify, description: "Noticed something")
        XCTAssertFalse(vm.actionFlash, "notify must not flash")
        XCTAssertTrue(vm.recentActions.isEmpty, "notify must not be recorded as a substantial action")
    }

    /// The self-deploy case: the relaunched app announces "Supervisor
    /// updated itself" and that must drive the same flash + label path.
    func testSelfRebuildAnnounceFlashesAndLabels() {
        let vm = makeVM()
        vm.announceSelfRebuild(version: "v0.9.1")
        XCTAssertTrue(vm.actionFlash, "self-rebuild announce must flash")
        XCTAssertTrue(vm.plainLabel.contains("updated itself"),
            "self-rebuild announce must surface the 'updated itself' label; got: \(vm.plainLabel)")
        XCTAssertEqual(vm.recentActions.first?.action, .selfExtend)
    }

    /// Every substantial action type surfaces a non-empty label with the flash
    /// (so the user always sees WHAT happened, not a bare glow).
    func testEverySubstantialActionSurfacesALabel() {
        for action in [FlagAction.inject, .continue, .selfExtend, .pause, .kill] {
            let vm = makeVM()
            let label = HoverViewModel.plainLabelForFlag(action: action, reasoningPlain: nil)
            vm.recordAction(action: action, description: label)
            XCTAssertTrue(vm.actionFlash, "\(action.rawValue) must flash")
            XCTAssertFalse(vm.plainLabel.isEmpty, "\(action.rawValue) must surface a label")
            XCTAssertEqual(vm.plainLabel, label)
        }
    }
}
