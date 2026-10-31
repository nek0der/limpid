// FocusedWindowCommandTests.swift
// Weir — which window a menu command acts on.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct FocusedWindowCommandTests {
    @Test func noWindowEverKey_isTheBackgroundTarget_thePrimary() {
        let registry = WindowRegistry(primaryID: WindowID())
        #expect(registry.backgroundCommandTarget === registry.primary)
    }

    @Test func aHiddenLastKeyWindow_givesWayToThePrimary() {
        let registry = WindowRegistry(primaryID: WindowID())
        let other = registry.addWindow(WindowID())
        registry.windowBecameKey(other.id)

        registry.hide(other.id)

        #expect(registry.backgroundCommandTarget === registry.primary)
    }

    /// ⌘W is one menu item for the whole app, so with no supervision
    /// window key it has to stand in for the standard Close — enabled, and
    /// closing the key window — rather than go dark and leave ⌘W dead in
    /// Settings. A supervision window with nothing to close keeps it off.
    @Test func closeKey_closesTheKeyWindow_whenNoSupervisionWindowIsKey() {
        let registry = WindowRegistry(primaryID: WindowID())
        registry.windowBecameKey(registry.primary.id)

        let inSettings = CloseKeyCommand.decide(isQuickTerminalKey: false, target: nil, hasActiveTab: false)
        #expect(inSettings == .closeKeyWindow)
        #expect(inSettings.isLive)

        let emptyWindow = CloseKeyCommand.decide(isQuickTerminalKey: false, target: registry.primary, hasActiveTab: false)
        #expect(emptyWindow == .nothing)
        #expect(!emptyWindow.isLive)

        let withTab = CloseKeyCommand.decide(isQuickTerminalKey: false, target: registry.primary, hasActiveTab: true)
        #expect(withTab == .closePaneOrTab)

        registry.primary.review = ReviewTabState(
            root: "/repo",
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        #expect(CloseKeyCommand.decide(isQuickTerminalKey: false, target: registry.primary, hasActiveTab: true) == .closeReview)
        // The quick terminal's panel comes first, whatever is behind it.
        #expect(CloseKeyCommand.decide(isQuickTerminalKey: true, target: nil, hasActiveTab: false) == .hideQuickTerminal)
    }

    /// The item's one label has to be true of everything above: it closes
    /// Settings and the review tab as well as a pane, so it cannot say
    /// "Close Pane". The menu and Settings › Keyboard read the same name.
    @Test func closeKey_isNamedClose_inBothLanguages() {
        let title = WeirShortcutAction.closeSurface.localizedTitle
        #expect(title.resolved(in: Locale(identifier: "en")) == "Close")
        #expect(title.resolved(in: Locale(identifier: "ja")) == "閉じる")
    }

    /// Until AppKit has reported a key window, a menu command has no
    /// window to act in.
    @Test func beforeAnyWindowIsKey_noWindowIsTheTarget() {
        let registry = WindowRegistry(primaryID: WindowID())
        _ = registry.addWindow(WindowID())
        #expect(registry.commandTarget == nil)
    }

    /// A supervision window that AppKit made key is the target however the
    /// keyboard sits inside it, including with a terminal first responder,
    /// for which SwiftUI publishes no focused value; ⌘W closes its pane.
    @Test func aWindowAppKitMadeKey_isTheTarget_andCmdWClosesItsPane() {
        let registry = WindowRegistry(primaryID: WindowID())
        let other = registry.addWindow(WindowID())

        registry.windowBecameKey(other.id)

        #expect(registry.commandTarget === other)
        #expect(registry.backgroundCommandTarget === other)
        #expect(CloseKeyCommand.decide(
            isQuickTerminalKey: false,
            target: registry.commandTarget,
            hasActiveTab: true
        ) == .closePaneOrTab)
    }

    /// Settings (or any window that is not a supervision window) taking the
    /// keyboard resigns the main window and nothing of ours becomes key: the
    /// window-scoped items have no window to act in, and ⌘W is Settings' own
    /// Close rather than closing a tab behind it. What has no keyboard to
    /// read (a toast, a notification's click, ⌘J) still acts in the window
    /// last key.
    @Test func settingsTakingTheKeyboard_leavesNoTarget_andCmdWClosesSettings() {
        let registry = WindowRegistry(primaryID: WindowID())
        let other = registry.addWindow(WindowID())
        registry.windowBecameKey(other.id)

        registry.windowResignedKey(other.id)

        let target = registry.commandTarget
        #expect(target == nil)
        #expect(!ReviewTabModel.closeCommandsAreLive(hasActiveTab: target != nil, review: target?.review))
        #expect(CloseKeyCommand.decide(isQuickTerminalKey: false, target: target, hasActiveTab: true) == .closeKeyWindow)
        #expect(registry.backgroundCommandTarget === other)
        // ⌘J reads the key window, else the background target.
        #expect((registry.commandTarget ?? registry.backgroundCommandTarget) === other)
    }

    /// Moving between main windows, AppKit resigns the old one first and
    /// then the new one becomes key; a resign of the old one that arrives
    /// after the new one reported changes nothing.
    @Test func movingToAnotherWindow_makesItTheTarget_evenWhenTheOldOneResignsLate() {
        let registry = WindowRegistry(primaryID: WindowID())
        let other = registry.addWindow(WindowID())
        registry.windowBecameKey(other.id)

        registry.windowResignedKey(other.id)
        registry.windowBecameKey(registry.primary.id)
        #expect(registry.commandTarget === registry.primary)

        registry.windowResignedKey(other.id)
        #expect(registry.commandTarget === registry.primary)
    }

    /// Hidden or closed, a window has no keyboard whether or not AppKit has
    /// said so yet.
    @Test func aHiddenKeyWindow_isNotTheTarget() {
        let registry = WindowRegistry(primaryID: WindowID())
        registry.windowBecameKey(registry.primary.id)

        registry.hide(registry.primary.id)

        #expect(registry.commandTarget == nil)
    }

    @Test func anUnknownWindowBecomingKey_changesNothing() {
        let registry = WindowRegistry(primaryID: WindowID())
        let other = registry.addWindow(WindowID())
        registry.windowBecameKey(other.id)

        registry.windowBecameKey(WindowID())

        #expect(registry.backgroundCommandTarget === other)
    }
}
