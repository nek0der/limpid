// FloatingSurfaceCoordinatorTests.swift
// Limpid — one floating panel at a time: which surfaces give way when
// another presents, what keeps the prompt cache panel from opening under the
// pointer, and the coordinator carrying that out against real presentations.

import CoreGraphics
import Foundation
import Testing
@testable import Limpid

struct FloatingSurfaceRulesTests {
    @Test func aFloatingPanel_closesTheOtherFloatingPanels() {
        #expect(
            FloatingSurfaceRules.surfacesToClose(
                whenPresenting: .containerColor,
                open: [.promptCache, .containerColor, .paneRename]
            ) == [.promptCache, .paneRename]
        )
        #expect(
            FloatingSurfaceRules.surfacesToClose(whenPresenting: .paneRename, open: [.promptCache, .containerColor])
                == [.promptCache, .containerColor]
        )
    }

    @Test func aWorkingSurface_closesTheCacheAndColorPanels_butLeavesARenameToEndItself() {
        for kind in [FloatingSurfaceKind.commandPalette, .approvalCard, .notificationHistory, .review] {
            #expect(
                FloatingSurfaceRules.surfacesToClose(
                    whenPresenting: kind,
                    open: [kind, .promptCache, .containerColor, .paneRename]
                ) == [.promptCache, .containerColor]
            )
        }
    }

    @Test func thePRCard_closesNothing() {
        #expect(
            FloatingSurfaceRules.surfacesToClose(whenPresenting: .prCard, open: [.prCard, .promptCache, .containerColor])
                .isEmpty
        )
    }

    @Test func surfacesOfTheAppItself_areNeverClosedFromHere() {
        let appSurfaces: Set<FloatingSurfaceKind> = [.commandPalette, .approvalCard, .notificationHistory, .prCard, .review]
        for kind in FloatingSurfaceKind.allCases {
            let closing = FloatingSurfaceRules.surfacesToClose(whenPresenting: kind, open: Set(FloatingSurfaceKind.allCases))
            #expect(closing.isDisjoint(with: appSurfaces))
            #expect(!closing.contains(kind))
        }
    }

    @Test func pointerOpens_waitWhileAnythingElseFloats() {
        #expect(!FloatingSurfaceRules.isAnotherSurfaceOpen(than: .promptCache, open: []))
        #expect(!FloatingSurfaceRules.isAnotherSurfaceOpen(than: .promptCache, open: [.promptCache]))
        for kind in FloatingSurfaceKind.allCases where kind != .promptCache {
            #expect(FloatingSurfaceRules.isAnotherSurfaceOpen(than: .promptCache, open: [kind]))
        }
    }
}

@MainActor
struct FloatingSurfaceCoordinatorTests {
    private let anchor = CGRect(x: 40, y: 80, width: 16, height: 16)

    private func openCache(_ presentation: PromptCachePanelPresentation) {
        let place = PromptCacheClockPlace.tabRow(tabID: UUID())
        presentation.clockMoved(place: place, instance: UUID(), anchor: anchor)
        presentation.open(
            target: PromptCacheTarget(runtimeID: "claude:run", paneID: UUID()),
            place: place,
            trigger: .accessibility
        )
    }

    @Test func colorPickerOpening_closesTheCachePanelAndEndsARename() {
        let cache = PromptCachePanelPresentation()
        let color = ContainerColorPresentation()
        var renameEnded = false
        let coordinator = FloatingSurfaceCoordinator(promptCache: cache, containerColor: color) { renameEnded = true }
        openCache(cache)
        color.open(container: .group(UUID()), anchor: anchor)

        coordinator.makeWay(for: .containerColor, open: [.promptCache, .containerColor, .paneRename])
        #expect(cache.request == nil)
        #expect(color.request != nil)
        #expect(renameEnded, "opened by keyboard or VoiceOver, nothing else would end it")
    }

    @Test func commandPaletteOpening_closesBothPanels() {
        let cache = PromptCachePanelPresentation()
        let color = ContainerColorPresentation()
        var renameEnded = false
        let coordinator = FloatingSurfaceCoordinator(promptCache: cache, containerColor: color) { renameEnded = true }
        openCache(cache)
        color.open(container: .project(UUID()), anchor: anchor)

        coordinator.makeWay(for: .commandPalette, open: [.commandPalette, .promptCache, .containerColor, .paneRename])
        #expect(cache.request == nil)
        #expect(color.request == nil)
        #expect(!renameEnded, "the palette takes the keyboard, which ends the rename by itself")
    }

    @Test func twoPanelsOpeningTogether_doNotCloseEachOther() {
        let cache = PromptCachePanelPresentation()
        let color = ContainerColorPresentation()
        let coordinator = FloatingSurfaceCoordinator(promptCache: cache, containerColor: color) {}
        openCache(cache)
        color.open(container: .group(UUID()), anchor: anchor)

        // Both report presenting in the same update. The first closes the
        // second; the second, no longer open, then closes nothing.
        coordinator.makeWay(for: .promptCache, open: [.promptCache, .containerColor])
        #expect(color.request == nil)
        coordinator.makeWay(for: .containerColor, open: [.promptCache])
        #expect(cache.request != nil, "one panel stays")
    }
}

struct FloatingSurfaceBlockingTests {
    @Test func workingSurfaces_keepTheCacheAndColorPanelsFromOpening() {
        for working in [FloatingSurfaceKind.commandPalette, .approvalCard, .notificationHistory, .review] {
            #expect(FloatingSurfaceRules.isOpeningBlocked(.promptCache, open: [working]))
            #expect(FloatingSurfaceRules.isOpeningBlocked(.containerColor, open: [working]))
            #expect(!FloatingSurfaceRules.isOpeningBlocked(.paneRename, open: [working]), "a rename is not one of them")
        }
    }

    @Test func peeksAndOtherPanels_doNotBlockAnOpening() {
        for kind in [FloatingSurfaceKind.prCard, .approvalPreview, .paneRename, .promptCache, .containerColor] {
            #expect(!FloatingSurfaceRules.isOpeningBlocked(.containerColor, open: [kind]))
            #expect(!FloatingSurfaceRules.isOpeningBlocked(.promptCache, open: [kind]))
        }
    }

    @Test func anApprovalPreview_closesNothing() {
        #expect(
            FloatingSurfaceRules.surfacesToClose(
                whenPresenting: .approvalPreview,
                open: [.approvalPreview, .containerColor, .promptCache]
            ).isEmpty
        )
        // It still holds back pointer opens of the cache panel, as the PR
        // card does.
        #expect(FloatingSurfaceRules.isAnotherSurfaceOpen(than: .promptCache, open: [.approvalPreview]))
    }
}

@MainActor
struct FloatingSurfaceGateTests {
    private let anchor = CGRect(x: 40, y: 80, width: 16, height: 16)

    @Test func gates_followWhatIsOpen() {
        let cache = PromptCachePanelPresentation()
        let color = ContainerColorPresentation()
        let coordinator = FloatingSurfaceCoordinator(promptCache: cache, containerColor: color) {}

        coordinator.updateGates(open: [.prCard])
        #expect(cache.isAnotherSurfaceOpen)
        #expect(!cache.isOpeningBlocked)
        #expect(!color.isOpeningBlocked)

        coordinator.updateGates(open: [.commandPalette])
        #expect(cache.isOpeningBlocked)
        #expect(color.isOpeningBlocked)

        coordinator.updateGates(open: [])
        #expect(!cache.isAnotherSurfaceOpen)
        #expect(!cache.isOpeningBlocked)
        #expect(!color.isOpeningBlocked)
    }

    @Test func blockedPanels_refuseEveryKindOfOpening() {
        let cache = PromptCachePanelPresentation()
        let color = ContainerColorPresentation()
        let coordinator = FloatingSurfaceCoordinator(promptCache: cache, containerColor: color) {}
        coordinator.updateGates(open: [.notificationHistory])

        color.open(container: .group(UUID()), anchor: anchor)
        #expect(color.request == nil, "Change Color does nothing over the history")

        let place = PromptCacheClockPlace.tabRow(tabID: UUID())
        let target = PromptCacheTarget(runtimeID: "claude:run", paneID: UUID())
        cache.clockClicked(place: place, instance: UUID(), anchor: anchor, target: target)
        #expect(cache.request == nil, "a click is refused too")
        #expect(!cache.open(target: target, place: place, trigger: .automatic), "and the panel that opens by itself")
    }

    @Test func makeWay_handlesEachNewlyPresentedSurfaceAgainstTheLiveSet() {
        let cache = PromptCachePanelPresentation()
        let color = ContainerColorPresentation()
        let coordinator = FloatingSurfaceCoordinator(promptCache: cache, containerColor: color) {}
        let place = PromptCacheClockPlace.tabRow(tabID: UUID())
        cache.clockMoved(place: place, instance: UUID(), anchor: anchor)
        cache.open(target: PromptCacheTarget(runtimeID: "claude:run", paneID: UUID()), place: place, trigger: .accessibility)
        color.open(container: .group(UUID()), anchor: anchor)

        func live() -> Set<FloatingSurfaceKind> {
            var open: Set<FloatingSurfaceKind> = []
            if cache.request != nil {
                open.insert(.promptCache)
            }
            if color.request != nil {
                open.insert(.containerColor)
            }
            return open
        }
        // Both appeared in one update. In `FloatingSurfaceKind` order the
        // cache panel goes first and closes the color picker, which then has
        // nothing left to close.
        coordinator.makeWay(from: [], to: [.promptCache, .containerColor], live: live)
        #expect(cache.request != nil)
        #expect(color.request == nil)

        // A surface already open before the update is not handled again.
        color.open(container: .group(UUID()), anchor: anchor)
        coordinator.makeWay(from: [.containerColor], to: [.containerColor], live: live)
        #expect(cache.request != nil)
        #expect(color.request != nil)
    }
}
