// OverlayOwnershipTests.swift
// Weir — each window draws its own overlays: the approval card, toasts, and floating panels.

import CoreGraphics
import Foundation
import Testing
@testable import Weir

@MainActor
struct OverlayOwnershipTests {
    @Test func aCardOpenedInOneWindow_isNotShownInAnother_andItsFocusHoldsBackOnlyItsOwn() {
        let store = ApprovalPresentationStore()
        let request = ApprovalPresentation.test(deadlineMilliseconds: 0)
        store.receive([request])
        let first = WindowApprovalCard()
        let second = WindowApprovalCard()

        first.present(request, from: store)
        first.updateRowAnchor(CGRect(x: 0, y: 40, width: 200, height: 20), for: request, in: store)
        first.focusChanged(true, for: request)

        #expect(first.presentedApproval(in: store)?.id == request.id)
        #expect(second.presentedApproval(in: store) == nil)
        // What hides the row's Answer… and marks the all projects card.
        #expect(first.isPresenting(request.key, in: store))
        #expect(!second.isPresenting(request.key, in: store))
        #expect(first.isFocused)
        #expect(!second.isFocused, "⌘⏎ in the other window is not held back")
        #expect(second.rowAnchor(for: request) == nil, "a row in one window is no anchor in another")

        // The same request opened in the second window too: each has its own.
        second.present(request, from: store)
        first.dismiss()
        #expect(first.presentedApproval(in: store) == nil)
        #expect(second.presentedApproval(in: store)?.id == request.id)
    }

    @Test func aCardOpenedFromTheTitleBarList_standsBesideIt_andTheSidebarGoingTakesTheRowsAway() {
        let store = ApprovalPresentationStore()
        let request = ApprovalPresentation.test(deadlineMilliseconds: 0)
        store.receive([request])
        let card = WindowApprovalCard()
        let pill = CGRect(x: 900, y: 10, width: 80, height: 24)
        card.updateRowAnchor(CGRect(x: 0, y: 40, width: 200, height: 20), for: request, in: store)

        card.present(request, from: store, openedFrom: pill)
        #expect(card.state.openedFrom == pill)
        // Opened from its row in the sidebar, it stands beside the row again.
        card.present(request, from: store)
        #expect(card.state.openedFrom == nil)

        card.clearRowAnchors()
        #expect(card.rowAnchor(for: request) == nil)
        // A card dismissed is back to nothing.
        card.dismiss()
        #expect(card.state == ApprovalCardState())
    }

    @Test func everyWindowsCard_followsTheRequestsTheyShare() {
        // A settled request closes its card in each window that showed it,
        // and a row whose request is gone loses its frame there.
        let store = ApprovalPresentationStore()
        let registry = WindowRegistry(primary: WindowSelection())
        let second = registry.addWindow(WindowSelection())
        store.onRequestsChanged = { [weak registry, weak store] in
            guard let registry, let store else { return }
            registry.settleApprovalCards(against: store)
        }
        let request = ApprovalPresentation.test(deadlineMilliseconds: 0)
        store.receive([request])
        for window in [registry.primary, second] {
            window.approvalCard.present(request, from: store)
            window.approvalCard.updateRowAnchor(CGRect(x: 0, y: 40, width: 200, height: 20), for: request, in: store)
        }

        // Withdrawn: the ledger still holds it, so its row keeps its frame.
        store.receive([], epoch: request.epoch, terminals: [request.id: .canceled])

        for window in [registry.primary, second] {
            #expect(window.approvalCard.state.presentedID == nil)
            #expect(window.approvalCard.rowAnchor(for: request) != nil)
        }

        // The service restarted: the request is gone with its epoch.
        store.receive([], epoch: UUID())

        for window in [registry.primary, second] {
            #expect(window.approvalCard.rowAnchor(for: request) == nil)
        }
    }

    @Test func aToast_showsInItsWindow_andGoesWhereverItIs() {
        let toasts = ToastCenter()
        let first = WindowID()
        let second = WindowID()
        let item = ToastItem(message: .verbatim("Done"), undo: nil)

        toasts.show(item, in: first)
        #expect(toasts.current(in: first)?.id == item.id)
        #expect(toasts.current(in: second) == nil)

        // Its action taken back elsewhere: it goes, whichever window has it.
        toasts.dismiss(item.id)
        #expect(toasts.current(in: first) == nil)

        // A caller that knows no window shows it in the one in front.
        toasts.frontWindow = { second }
        toasts.show(item)
        #expect(toasts.current(in: second)?.id == item.id)
        #expect(toasts.current(in: first) == nil)
    }

    @Test func eachWindow_hasItsOwnFloatingPanels() {
        let first = ProjectWindowState(id: WindowID())
        let second = ProjectWindowState(id: WindowID())

        first.notificationHistory.isPresented = true
        first.paneRename.open(paneID: UUID(), name: "agent", anchor: .zero)

        #expect(!second.notificationHistory.isPresented)
        #expect(second.paneRename.request == nil)
        #expect(first.prHover !== second.prHover)
        #expect(first.promptCachePanel !== second.promptCachePanel)
        #expect(first.containerColor !== second.containerColor)
    }
}
