// TmuxOutputGateTests.swift
// Limpid — pins the pause/resume diff a control connection sends when the mirrored windows change.

import Foundation
import Testing
@testable import Limpid

@Suite("tmux output gate")
struct TmuxOutputGateTests {
    /// Two windows, the second holding two panes, as `list-panes -s` reports them.
    private func twoWindows() -> TmuxOutputGate {
        var gate = TmuxOutputGate()
        gate.replaceAll([("@0", "%0"), ("@1", "%1"), ("@1", "%2")])
        return gate
    }

    @Test("panes of a hidden window are paused in one command")
    func reconcile_pausesHiddenWindows() {
        var gate = twoWindows()
        #expect(gate.reconcile(shownWindows: ["@0"]) == ["refresh-client -A '%1:off' -A '%2:off'"])
        #expect(gate.silenced == ["%1", "%2"])
    }

    @Test("switching the shown window pauses and resumes in the same command")
    func reconcile_switchingWindow() {
        var gate = twoWindows()
        _ = gate.reconcile(shownWindows: ["@0"])
        #expect(gate.reconcile(shownWindows: ["@1"]) == ["refresh-client -A '%0:off' -A '%1:on' -A '%2:on'"])
        #expect(gate.silenced == ["%0"])
    }

    @Test("a reconcile that changes nothing sends nothing")
    func reconcile_noChange() {
        var gate = twoWindows()
        _ = gate.reconcile(shownWindows: ["@0"])
        #expect(gate.reconcile(shownWindows: ["@0"]).isEmpty)
        #expect(gate.silenced == ["%1", "%2"])
    }

    @Test("showing every window leaves no pane paused")
    func reconcile_allShown() {
        var gate = twoWindows()
        _ = gate.reconcile(shownWindows: ["@0"])
        #expect(gate.reconcile(shownWindows: ["@0", "@1"]) == ["refresh-client -A '%1:on' -A '%2:on'"])
        #expect(gate.silenced.isEmpty)
    }

    @Test("showing no window pauses every known pane")
    func reconcile_nothingShown() {
        var gate = twoWindows()
        #expect(gate.reconcile(shownWindows: []) == ["refresh-client -A '%0:off' -A '%1:off' -A '%2:off'"])
    }

    @Test("a window we do not know is ignored")
    func reconcile_unknownWindow() {
        var gate = twoWindows()
        #expect(gate.reconcile(shownWindows: ["@0", "@9"]) == ["refresh-client -A '%1:off' -A '%2:off'"])
    }

    @Test("a closed window's panes are forgotten rather than resumed")
    func removeWindow_forgetsPanes() {
        var gate = twoWindows()
        _ = gate.reconcile(shownWindows: ["@0"])
        gate.removeWindow("@1")
        #expect(gate.silenced.isEmpty)
        #expect(gate.reconcile(shownWindows: ["@0"]).isEmpty)
    }

    @Test("a pane dropped by a layout change is forgotten, the rest stay paused")
    func setPanes_forgetsDroppedPane() {
        var gate = twoWindows()
        _ = gate.reconcile(shownWindows: ["@0"])
        gate.setPanes(["%1"], ofWindow: "@1")
        #expect(gate.silenced == ["%1"])
        #expect(gate.reconcile(shownWindows: ["@0"]).isEmpty)
    }

    @Test("a pane added to a hidden window is paused on the next reconcile")
    func setPanes_pausesNewPane() {
        var gate = twoWindows()
        _ = gate.reconcile(shownWindows: ["@0"])
        gate.setPanes(["%1", "%2", "%3"], ofWindow: "@1")
        #expect(gate.reconcile(shownWindows: ["@0"]) == ["refresh-client -A '%3:off'"])
    }

    @Test("replaceAll forgets panes the new listing no longer has")
    func replaceAll_forgetsMissingPanes() {
        var gate = twoWindows()
        _ = gate.reconcile(shownWindows: ["@0"])
        gate.replaceAll([("@0", "%0"), ("@1", "%2")])
        #expect(gate.panesByWindow == ["@0": ["%0"], "@1": ["%2"]])
        #expect(gate.silenced == ["%2"])
    }

    @Test("pane ids are ordered by number, not by text")
    func reconcile_ordersPaneIDsNumerically() {
        var gate = TmuxOutputGate()
        gate.replaceAll([("@0", "%9"), ("@0", "%10"), ("@0", "%2")])
        #expect(gate.reconcile(shownWindows: []) == ["refresh-client -A '%2:off' -A '%9:off' -A '%10:off'"])
    }

    @Test("an id without a number sorts after the numbered ones")
    func reconcile_ordersUnnumberedIDsLast() {
        var gate = TmuxOutputGate()
        gate.replaceAll([("@0", "%b"), ("@0", "%1"), ("@0", "%a")])
        #expect(gate.reconcile(shownWindows: []) == ["refresh-client -A '%1:off' -A '%a:off' -A '%b:off'"])
    }
}
