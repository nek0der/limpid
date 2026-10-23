// SidebarKeyRouteTests.swift
// Limpid — Move Project Up and Down: their keys, only while the sidebar has the keyboard.

import Foundation
import Testing
@testable import Limpid

struct SidebarKeyRouteTests {
    typealias Route = SidebarKeyRoute

    private static let optionCommandUp = StoredShortcut(key: "up", modifiers: [.command, .option])
    private static let optionCommandDown = StoredShortcut(key: "down", modifiers: [.command, .option])
    private static let controlCommandK = StoredShortcut(key: "k", modifiers: [.command, .control])
    private static let controlCommandJ = StoredShortcut(key: "j", modifiers: [.command, .shift, .control])

    private static func route(
        _ pressed: StoredShortcut?,
        _ keyboard: KeyboardSettings = KeyboardSettings(),
        hasKeyboard: Bool = true,
        isComposing: Bool = false
    ) -> Route.Route {
        Route.route(pressed: pressed, keyboard: keyboard, hasKeyboard: hasKeyboard, isComposing: isComposing)
    }

    @Test func theDefaultKeys_moveTheProject_whileTheSidebarHasTheKeyboard() {
        #expect(Self.route(Self.optionCommandUp) == .moveProject(by: -1))
        #expect(Self.route(Self.optionCommandDown) == .moveProject(by: 1))
    }

    /// Without the keyboard in the sidebar, the keys go on to the menus, so
    /// focus still moves between a split tab's panes with them.
    @Test func withoutTheKeyboard_theKeysGoOnToThePaneMenu() {
        #expect(Self.route(Self.optionCommandUp, hasKeyboard: false) == .pass)
        #expect(Self.route(Self.optionCommandDown, hasKeyboard: false) == .pass)
    }

    /// Rebound in Settings → Keyboard, the moves answer to their new keys,
    /// and ⌥⌘↑ ⌥⌘↓ go on to the pane menu even while the sidebar has the
    /// keyboard.
    @Test func reboundMoves_answerToTheirNewKeys_andTheOldOnesGoOnToThePanes() {
        var keyboard = KeyboardSettings()
        keyboard.setOverride(Self.controlCommandK, for: .moveProjectUp)
        keyboard.setOverride(Self.controlCommandJ, for: .moveProjectDown)

        #expect(Self.route(Self.controlCommandK, keyboard) == .moveProject(by: -1))
        #expect(Self.route(Self.controlCommandJ, keyboard) == .moveProject(by: 1))
        #expect(Self.route(Self.optionCommandUp, keyboard) == .pass)
        #expect(Self.route(Self.optionCommandDown, keyboard) == .pass)
        #expect(Self.route(Self.controlCommandK, keyboard, hasKeyboard: false) == .pass)
    }

    /// An unassigned move takes no key, and its default goes on.
    @Test func anUnassignedMove_takesNoKey() {
        var keyboard = KeyboardSettings()
        keyboard.unassign(.moveProjectUp)
        #expect(Self.route(Self.optionCommandUp, keyboard) == .pass)
        #expect(Self.route(Self.optionCommandDown, keyboard) == .moveProject(by: 1))
    }

    @Test(arguments: [
        StoredShortcut(key: "up", modifiers: [.command, .option, .shift]),
        StoredShortcut(key: "up", modifiers: [.command, .option, .control]),
        StoredShortcut(key: "up", modifiers: [.command]),
        StoredShortcut(key: "up", modifiers: [.option]),
        StoredShortcut(key: "up", modifiers: [])
    ])
    func anyOtherModifiers_goOn(_ pressed: StoredShortcut) {
        #expect(Self.route(pressed) == .pass)
    }

    @Test func anotherKey_noKey_andAKeyTheInputMethodIsComposingWith_goOn() {
        #expect(Self.route(StoredShortcut(key: "a", modifiers: [.command, .option])) == .pass)
        #expect(Self.route(nil) == .pass)
        #expect(Self.route(Self.optionCommandUp, isComposing: true) == .pass)
    }

    // MARK: The keys the moves share with the pane focus moves

    /// The moves and the pane focus moves share ⌥⌘↑ ⌥⌘↓ by default, as they
    /// never answer in the same place; no other action may take the keys.
    @Test func theMoves_shareTheirDefaults_withThePaneMovesOnly() {
        let keyboard = KeyboardSettings()
        #expect(keyboard.shortcut(for: .moveProjectUp) == keyboard.shortcut(for: .focusPaneUp))
        #expect(keyboard.shortcut(for: .moveProjectDown) == keyboard.shortcut(for: .focusPaneDown))
        #expect(keyboard.validate(Self.optionCommandUp, for: .moveProjectUp) == .ok)
        #expect(keyboard.validate(Self.optionCommandUp, for: .focusPaneUp) == .ok)
        // Both of the pair hold it, and the refusal names both.
        #expect(keyboard.validate(Self.optionCommandUp, for: .newTab) == .conflictWithPair(.moveProjectUp, .focusPaneUp))
        let message = ShortcutValidation.conflictWithPair(.moveProjectUp, .focusPaneUp).message
        #expect(message?.resolved(in: Locale(identifier: "ja")).contains("プロジェクトを上へ移動") == true)
        #expect(message?.resolved(in: Locale(identifier: "en")).contains("Move Project Up") == true)
        // Up shares with up only.
        #expect(keyboard.validate(Self.optionCommandDown, for: .moveProjectUp) != .ok)
    }

    /// The sidebar folds and opens headers with ⌥← ⌥→ ahead of the menus,
    /// so the moves may not take those keys; other actions may.
    @Test func theMoves_mayNotTakeTheSidebarsOwnKeys() {
        let keyboard = KeyboardSettings()
        let optionLeft = StoredShortcut(key: "left", modifiers: [.option])
        #expect(keyboard.validate(optionLeft, for: .moveProjectUp) == .keptBySidebar)
        #expect(keyboard.validate(StoredShortcut(key: "right", modifiers: [.option]), for: .moveProjectDown) == .keptBySidebar)
        #expect(keyboard.validate(optionLeft, for: .newTab) == .ok)
        #expect(ShortcutValidation.keptBySidebar.message != nil)
    }

    /// Two actions on one set of keys both reach libghostty as `ignore`;
    /// if either became a libghostty action, the later line would win.
    @Test func thePairsThatShareKeys_areBothTheMenusOrTheSidebars() {
        for action in LimpidShortcutAction.allCases {
            guard let partner = action.sharesKeys else { continue }
            #expect(action.ghosttyAction == nil && partner.ghosttyAction == nil, "\(action)")
            #expect(partner.sharesKeys == action, "sharing goes both ways")
        }
    }

    /// A key a move takes is taken from every other action, as any key is.
    @Test func aReboundMove_holdsItsKeys_againstEveryOtherAction() {
        var keyboard = KeyboardSettings()
        keyboard.setOverride(Self.controlCommandK, for: .moveProjectUp)
        #expect(keyboard.validate(Self.controlCommandK, for: .newTab) == .conflict(.moveProjectUp))
        #expect(keyboard.validate(Self.controlCommandK, for: .focusPaneUp) == .ok, "the pane focus move may share it")
        #expect(keyboard.shortcut(for: .focusPaneUp) == Self.optionCommandUp, "the pane focus move keeps its own")
    }

    /// A person's own binding on ⌥⌘↑ for another action gives both defaults
    /// up, and the notice lists both; the pane focus move's own binding on the
    /// same keys does not give the project move's up.
    @Test func anotherActionsBinding_onTheSharedKeys_givesBothDefaultsUp() {
        var keyboard = KeyboardSettings()
        keyboard.overrides[LimpidShortcutAction.splitRight.rawValue] = Self.optionCommandUp
        var hotKey: StoredShortcut?
        keyboard.normalize(quickTerminalHotKey: &hotKey)
        #expect(keyboard.shortcut(for: .moveProjectUp) == nil)
        #expect(keyboard.shortcut(for: .focusPaneUp) == nil)
        #expect(Set(keyboard.unbound) == [LimpidShortcutAction.moveProjectUp.rawValue, LimpidShortcutAction.focusPaneUp.rawValue])

        var paneOwn = KeyboardSettings()
        paneOwn.overrides[LimpidShortcutAction.focusPaneUp.rawValue] = Self.optionCommandUp
        paneOwn.normalize(quickTerminalHotKey: &hotKey)
        #expect(paneOwn.shortcut(for: .moveProjectUp) == Self.optionCommandUp)
        #expect(paneOwn.unbound.isEmpty)
    }

    /// Settings → Keyboard and the ⌘/ sheet list the two with the other
    /// navigation keys, under their own names.
    @MainActor
    @Test func theMoves_areListedWithTheirNames() {
        let japanese = Locale(identifier: "ja")
        #expect(LimpidShortcutAction.moveProjectUp.category == .navigation)
        #expect(LimpidShortcutAction.moveProjectUp.localizedTitle.resolved(in: japanese) == "プロジェクトを上へ移動")
        #expect(LimpidShortcutAction.moveProjectDown.localizedTitle.resolved(in: japanese) == "プロジェクトを下へ移動")
        let sections = KeyboardShortcutCatalog.sections(
            keyboard: KeyboardSettings(),
            quickTerminalHotKey: nil,
            locale: Locale(identifier: "en")
        )
        let navigation = sections.first { $0.id == "category.\(LimpidShortcutCategory.navigation.rawValue)" }
        let titles = navigation?.entries.map(\.title) ?? []
        #expect(titles.contains("Move Project Up"))
        #expect(titles.contains("Move Project Down"))
    }
}
