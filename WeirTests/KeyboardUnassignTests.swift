// KeyboardUnassignTests.swift
// Weir — a shortcut unassigned from Settings stays unassigned, comes back with ↺, and ⌫ means the same in both recorders.

import Foundation
import Testing
@testable import Weir

@MainActor
struct KeyboardUnassignTests {
    private static let commandN = TestShortcuts.commandN
    private static let optionCommandN = TestShortcuts.optionCommandN

    private static func normalized(_ keyboard: KeyboardSettings, hotKey: StoredShortcut? = nil) -> KeyboardSettings {
        keyboard.normalizedForTest(hotKey: hotKey).keyboard
    }

    @Test func unassigningADefault_survivesNormalizingAndASave_andRestoringBringsItBack() throws {
        var keyboard = KeyboardSettings()
        keyboard.unassign(.newWorktree)
        keyboard = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        #expect(keyboard.canRestoreDefault(.newWorktree))
        let saved = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(keyboard))
        #expect(Self.normalized(saved).shortcut(for: .newWorktree) == nil)

        keyboard.restoreDefault(for: .newWorktree)
        keyboard = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandN)
        #expect(!keyboard.canRestoreDefault(.newWorktree))
    }

    @Test func unassigningAnOverride_dropsItAndTheDefault() {
        var keyboard = KeyboardSettings()
        keyboard.setOverride(Self.optionCommandN, for: .newWorktree)
        keyboard.unassign(.newWorktree)
        keyboard = Self.normalized(keyboard)

        #expect(keyboard.overrides.isEmpty)
        #expect(keyboard.shortcut(for: .newWorktree) == nil)
    }

    @Test func unassigningAnActionWithoutADefault_onlyDropsItsBinding() {
        var keyboard = KeyboardSettings()
        keyboard.setOverride(Self.optionCommandN, for: .newWindow)
        keyboard.unassign(.newWindow)
        keyboard = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .newWindow) == nil)
        #expect(keyboard.unbound.isEmpty)
        #expect(!keyboard.canRestoreDefault(.newWindow))
    }

    @Test func anUnassignedDefault_staysOff_whenItsKeysAreTakenAndFreedAgain() {
        // Unassign New Worktree…, put ⌘N on New Tab, then give New Tab its
        // default back: ⌘N is free, and still New Worktree… stays off.
        var keyboard = KeyboardSettings()
        keyboard.unassign(.newWorktree)
        keyboard.setOverride(Self.commandN, for: .newTab)
        keyboard = Self.normalized(keyboard)
        keyboard.restoreDefault(for: .newTab)
        keyboard = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        #expect(keyboard.shortcut(for: .newTab) == WeirShortcutAction.newTab.defaultShortcut)
        #expect(keyboard.unassigned == [WeirShortcutAction.newWorktree.rawValue])
    }

    @Test func anUnassignedDefaultWhoseKeysAreTakenLater_isNoUpdateNotice() {
        // Unassigned, then its ⌘N given to another action or to the hotkey:
        // the person's own choices, not something the update changed.
        var keyboard = KeyboardSettings()
        keyboard.unassign(.newWorktree)
        keyboard.setOverride(Self.commandN, for: .newTab)
        keyboard = Self.normalized(keyboard)
        #expect(keyboard.unbound.isEmpty)
        #expect(keyboard.migrationNotice == nil)

        var withHotKey = KeyboardSettings()
        withHotKey.unassign(.newWorktree)
        withHotKey = Self.normalized(withHotKey, hotKey: Self.commandN)
        #expect(withHotKey.migrationNotice == nil)
        #expect(withHotKey.shortcut(for: .newWorktree) == nil)
    }

    @Test func freeingTheKeys_bringsBackOnlyTheDefaultThatGaveWay() throws {
        let unassignedAction = try #require(WeirShortcutAction.allCases.first {
            $0 != .newWorktree && $0 != .newTab && $0.defaultShortcut != nil
        })
        var keyboard = KeyboardSettings()
        keyboard.unassign(unassignedAction)
        keyboard.setOverride(Self.commandN, for: .newTab)
        keyboard = Self.normalized(keyboard)
        #expect(keyboard.unbound == [WeirShortcutAction.newWorktree.rawValue])

        keyboard.resetOverride(for: .newTab)
        keyboard = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandN)
        #expect(keyboard.shortcut(for: unassignedAction) == nil)
    }

    @Test func aFileWithoutUnassigned_readsAsNone_andAnEmptyListIsNotWritten() throws {
        let old = try JSONDecoder().decode(KeyboardSettings.self, from: Data(#"{"overrides":{}}"#.utf8))
        #expect(old.unassigned.isEmpty)

        let written = try #require(String(bytes: JSONEncoder().encode(KeyboardSettings()), encoding: .utf8))
        #expect(!written.contains("unassigned"))
        var keyboard = KeyboardSettings()
        keyboard.unassign(.newWorktree)
        let roundTripped = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(keyboard))
        #expect(roundTripped.unassigned == [WeirShortcutAction.newWorktree.rawValue])
    }

    @Test func backspace_restoresTheDefault_andEscapeCancels_inBothRecorders() {
        #expect(ShortcutRecorderKey.meaning(of: .backspace) == .restoreDefault)
        #expect(ShortcutRecorderKey.meaning(of: .escape) == .cancel)
        #expect(ShortcutRecorderKey.meaning(of: .return) == .record)
        #expect(ShortcutRecorderKey.meaning(of: nil) == .record)
    }
}
