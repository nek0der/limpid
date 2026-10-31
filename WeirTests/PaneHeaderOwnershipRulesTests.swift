// PaneHeaderOwnershipRulesTests.swift
// Weir — ownership and warning selection without display stores or actors.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Pane header ownership rules")
struct PaneHeaderOwnershipRulesTests {
    private typealias Rules = PaneHeaderOwnershipRules

    private func run(
        _ id: String,
        endpoint: String? = "%1",
        parent: String? = nil,
        launched: UInt64? = 100,
        observed: UInt64? = nil,
        isKnown: Bool = true,
        isVisible: Bool = true,
        isActive: Bool = true,
        warns: Bool = false,
        updatedAt: TimeInterval = 1
    ) -> Rules.Run {
        Rules.Run(
            id: id,
            runID: id,
            parentRunID: parent,
            endpoint: endpoint.map {
                Rules.Endpoint(socketPath: "/tmp/fixture", serverPID: "1", serverStartedAt: "1", paneID: $0)
            },
            isKnown: isKnown,
            isVisible: isVisible,
            isActive: isActive,
            runsWithoutAsking: warns,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            launchOrder: launched,
            observedOrder: observed
        )
    }

    private func orders(_ runs: [Rules.Run]) -> [[Rules.Run]] {
        [runs, Array(runs.reversed()), Array(runs.dropFirst()) + Array(runs.prefix(1))]
    }

    @Test func noRunsHasNoOwnerOrAmbiguity() {
        #expect(Rules.select(from: []) == Rules.Selection(ownerID: nil, isAmbiguous: false))
    }

    @Test func aVisibleUnfocusedWarningWinsOverAFocusedNormalSplit() {
        let bypass = run("bypass", isActive: false, warns: true)
        let normal = run("normal", endpoint: "%2", updatedAt: 2)
        for input in orders([bypass, normal]) {
            #expect(Rules.select(from: input) == Rules.Selection(ownerID: "bypass", isAmbiguous: false))
        }
    }

    @Test func hiddenWindowsAndZoomedOutSplitsDoNotSupplySettings() {
        let hidden = run("hidden", isVisible: false, isActive: false, warns: true)
        let visible = run("visible", endpoint: "%2")
        #expect(Rules.select(from: [hidden, visible]).ownerID == "visible")
        #expect(Rules.select(from: [hidden]).ownerID == nil)
    }

    @Test func focusWinsBeforeRecencyWhenNeitherSplitWarns() {
        let inactive = run("inactive", isActive: false, updatedAt: 3)
        let active = run("active", endpoint: "%2", updatedAt: 1)
        #expect(Rules.select(from: [inactive, active]).ownerID == "active")
    }

    @Test func launchOrderReplacesAnOldWarningAtTheSameEndpoint() {
        let old = run("old", launched: 100, observed: 500, warns: true)
        let new = run("new", launched: 101, observed: 110)
        for input in orders([old, new]) {
            #expect(Rules.select(from: input) == Rules.Selection(ownerID: "new", isAmbiguous: false))
        }
    }

    @Test func anEndedReplacementDoesNotReviveAnUnrelatedOldRoot() {
        let old = run("old", launched: 100, observed: 500, warns: true)
        let ended = run("ended", launched: 101, observed: 110, isKnown: false)
        #expect(Rules.select(from: [ended, old]) == Rules.Selection(ownerID: nil, isAmbiguous: false))
    }

    @Test func anActiveChildSuppliesSettingsUntilItsParentReportsAgain() {
        let parent = run("parent", launched: 100, observed: 110, warns: true)
        let child = run("child", parent: "parent", launched: 101, observed: 120)
        #expect(Rules.select(from: [parent, child]).ownerID == "child")
        var resumed = parent
        resumed.observedOrder = 130
        for input in orders([resumed, child]) {
            #expect(Rules.select(from: input).ownerID == "parent")
        }
    }

    @Test func anEndedChildReturnsToItsKnownParent() {
        let parent = run("parent", launched: 100, observed: 110, warns: true)
        let child = run("child", parent: "parent", launched: 101, observed: 120, isKnown: false)
        #expect(Rules.select(from: [parent, child]).ownerID == "parent")
    }

    @Test func endedDescendantsReturnToTheNearestKnownAncestor() {
        let parent = run("parent", launched: 100, observed: 110)
        let child = run("child", parent: "parent", launched: 101, observed: 120, isKnown: false)
        let grandchild = run("grandchild", parent: "child", launched: 102, observed: 130, isKnown: false)
        for input in orders([parent, child, grandchild]) {
            #expect(Rules.select(from: input).ownerID == "parent")
        }
    }

    @Test func theLatestRootWinsEvenWhenAnOldFamilyReportsLater() {
        let parent = run("old-root", launched: 100, observed: 400, warns: true)
        let child = run("old-child", parent: "old-root", launched: 101, observed: 500)
        let replacement = run("replacement", launched: 200, observed: 210)
        for input in orders([parent, child, replacement]) {
            #expect(Rules.select(from: input).ownerID == "replacement")
        }
    }

    @Test func aParentAtAnotherEndpointDoesNotCreateAnAncestryLink() {
        let unrelated = run("parent", endpoint: "%2", launched: 100, observed: 110, isVisible: false)
        let child = run("child", parent: "parent", launched: 101, observed: 120, isKnown: false)
        #expect(Rules.select(from: [unrelated, child]).ownerID == nil)
    }

    @Test func cyclicParentsAndDuplicateInvocationIDsAreAmbiguous() {
        let parent = run("parent", parent: "child")
        let child = run("child", parent: "parent", launched: 101)
        #expect(Rules.select(from: [parent, child]).isAmbiguous)
        let duplicate = Rules.Run(
            id: "other-provider", runID: parent.runID, endpoint: parent.endpoint, updatedAt: parent.updatedAt
        )
        #expect(Rules.select(from: [parent, duplicate]).isAmbiguous)
    }

    @Test func equalLegacyStampsDoNotGuessByID() {
        let first = run("a", launched: nil)
        let second = run("z", launched: nil, warns: true)
        for input in orders([first, second]) {
            #expect(Rules.select(from: input).isAmbiguous)
        }
    }

    @Test func aNewerRunClearsAnOlderTieInEveryInputOrder() {
        let first = run("a", launched: 100)
        let second = run("b", launched: 100)
        let latest = run("latest", launched: 101)
        for input in orders([first, second, latest]) {
            #expect(Rules.select(from: input) == Rules.Selection(ownerID: "latest", isAmbiguous: false))
        }
    }

    @Test func hiddenAmbiguityDoesNotHideKnownVisibleSettings() {
        let first = run("a", launched: nil, isVisible: false)
        let second = run("b", launched: nil, isVisible: false)
        let visible = run("visible", endpoint: "%2")
        #expect(Rules.select(from: [first, second, visible]) == Rules.Selection(ownerID: "visible", isAmbiguous: false))
    }

    @Test func directTerminalsCompareDatesInsteadOfBootScopedOrders() {
        let old = run("old", endpoint: nil, launched: 500, observed: 600, warns: true, updatedAt: 1)
        let new = run("new", endpoint: nil, launched: 1, observed: 2, updatedAt: 2)
        for input in orders([old, new]) {
            #expect(Rules.select(from: input) == Rules.Selection(ownerID: "new", isAmbiguous: false))
        }
    }
}
