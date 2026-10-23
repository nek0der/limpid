// KeyboardOverrideMigrationTests.swift
// Limpid — moving keyboard settings to schema 2: renamed actions, new defaults, reserved ⌘⏎, and rollback.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct KeyboardOverrideMigrationTests {
    private static let commandN = TestShortcuts.commandN
    private static let commandF = TestShortcuts.commandF
    private static let commandReturn = TestShortcuts.commandReturn
    private static let optionCommandN = TestShortcuts.optionCommandN

    private static func normalized(_ keyboard: KeyboardSettings, hotKey: StoredShortcut? = nil) -> (KeyboardSettings, StoredShortcut?) {
        keyboard.normalizedForTest(hotKey: hotKey)
    }

    @Test func renamedCases_keepRawValues() {
        // Settings store overrides under these names; a rename must not move them.
        #expect(LimpidShortcutAction.nextSession.rawValue == "nextSection")
        #expect(LimpidShortcutAction.previousSession.rawValue == "previousSection")
        #expect(LimpidShortcutAction.review.rawValue == "reviewChanges")
        #expect(LimpidShortcutAction.reviewLatestTurn.rawValue == "reviewTurn")

        var keyboard = KeyboardSettings()
        keyboard.overrides["nextSection"] = Self.commandN
        #expect(keyboard.shortcut(for: .nextSession) == Self.commandN)
    }

    /// Toggle Tab Layout went with the tab column. A binding a person
    /// saved for it still reads, binds nothing, and holds no keys: here on
    /// ⌘B, Toggle Sidebar's default, which stays Toggle Sidebar's. It is
    /// written back as it was, for a build that still has the action.
    @Test func aBindingForTheRemovedToggleTabLayout_reads_holdsNoKeys_andIsKept() throws {
        let commandB = StoredShortcut(key: "b", modifiers: [.command])
        #expect(LimpidShortcutAction(rawValue: "toggleTabLayout") == nil)
        let data = try LimpidSettings.testFileData(version: 2, overrides: ["toggleTabLayout": commandB])

        var settings = try PersistenceCoders.makeDecoder().decode(LimpidSettings.self, from: data)
        settings.normalizeKeyboard()

        #expect(settings.keyboard.overrides["toggleTabLayout"] == commandB)
        #expect(settings.keyboard.unbound.isEmpty)
        #expect(settings.keyboard.retired.isEmpty)
        #expect(settings.keyboard.shortcut(for: .toggleSidebar) == commandB)
        let optionCommandT = StoredShortcut(key: "t", modifiers: [.command, .option])
        #expect(settings.keyboard.validate(optionCommandT, for: .newTab) == .ok)
        let saved = try PersistenceCoders.makeDecoder().decode(
            LimpidSettings.self,
            from: LimpidSettings.makeFileEncoder().encode(settings)
        )
        #expect(saved.keyboard.overrides["toggleTabLayout"] == commandB)
    }

    @Test func newDefaults_takeNoKeysAnotherDefaultOrAReservedOneHas() {
        let defaults = LimpidShortcutAction.allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } }
        for (index, (action, shortcut)) in defaults.enumerated() {
            #expect(!ReservedShortcuts.triggers.contains(shortcut.ghosttyTrigger), "\(action) uses a reserved key")
            // Only the pair that answers in different places may share
            // (`LimpidShortcutAction.sharesKeys`).
            for (other, otherShortcut) in defaults.dropFirst(index + 1) where !action.sharesKeys(with: other) {
                #expect(shortcut.ghosttyTrigger != otherShortcut.ghosttyTrigger, "\(action) and \(other) share a default")
            }
        }
        #expect(LimpidShortcutAction.newWorktree.defaultShortcut == Self.commandN)
        #expect(LimpidShortcutAction.goBack.defaultShortcut == nil)
        #expect(LimpidShortcutAction.showNeedsAttention.defaultShortcut == StoredShortcut(key: "j", modifiers: [.command, .control]))
    }

    @Test func unbound_removesDefault() {
        var keyboard = KeyboardSettings()
        keyboard.unbound = [LimpidShortcutAction.newWorktree.rawValue]
        #expect(keyboard.shortcut(for: .newWorktree) == nil)

        // Binding it by hand brings it back for good.
        keyboard.setOverride(Self.optionCommandN, for: .newWorktree)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.optionCommandN)
        #expect(keyboard.unbound.isEmpty)
    }

    /// ⌥⌘N makes a worktree at once by default. A person who had
    /// put ⌥⌘N on another action keeps it, and the new default gives way.
    @Test func optionCommandN_isCreateWorktreeNow_unlessThePersonBoundIt() {
        #expect(KeyboardSettings().shortcut(for: .newWorktreeNow) == Self.optionCommandN)
        var keyboard = KeyboardSettings()
        keyboard.overrides[LimpidShortcutAction.newWindow.rawValue] = Self.optionCommandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWindow) == Self.optionCommandN)
        #expect(keyboard.shortcut(for: .newWorktreeNow) == nil)
        #expect(keyboard.unbound == [LimpidShortcutAction.newWorktreeNow.rawValue])
        #expect(LimpidShortcutAction.newWorktreeNow.category == .file)
        #expect(LimpidShortcutAction.newWorktreeNow.localizedTitle.resolved(in: Locale(identifier: "ja")) == "今すぐワークツリーを作成")
    }

    @Test func conflictWithNewDefault_unbindsNewAction() throws {
        var keyboard = KeyboardSettings()
        // A person had put ⌘N on New Tab before ⌘N meant New Worktree….
        keyboard.overrides[LimpidShortcutAction.newTab.rawValue] = Self.commandN

        (keyboard, _) = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .newTab) == Self.commandN, "the person's binding wins")
        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        // A default held by another binding has no ↺: restoring it would
        // leave it given up.
        #expect(!keyboard.canRestoreDefault(.newWorktree))
        let notice = try #require(keyboard.migrationNotice)
        #expect(notice.conflicts == [.newWorktree])

        // Resetting New Worktree… does not take ⌘N back from New Tab.
        keyboard.resetOverride(for: .newWorktree)
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == nil)
        // Freeing ⌘N brings the default back, and the notice goes with it.
        keyboard.resetOverride(for: .newTab)
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandN)
        #expect(keyboard.migrationNotice == nil)
    }

    @Test func aGivenUpDefault_namesWhatHoldsItsKeys() {
        var keyboard = KeyboardSettings()
        keyboard.overrides[LimpidShortcutAction.newTab.rawValue] = Self.commandN
        #expect(keyboard.holderOfDefault(for: .newWorktree, quickTerminalHotKey: nil) == .action(.newTab))
        keyboard.overrides.removeAll()
        #expect(keyboard.holderOfDefault(for: .newWorktree, quickTerminalHotKey: Self.commandN) == .quickTerminalHotKey)
        #expect(keyboard.holderOfDefault(for: .newWorktree, quickTerminalHotKey: nil) == nil)
        #expect(keyboard.holderOfDefault(for: .newWindow, quickTerminalHotKey: nil) == nil, "no default, nothing to hold")
    }

    @Test func aStaleUnboundEntry_isDroppedOnceItsKeysAreFree() {
        // An earlier load gave New Worktree… up; the binding that held ⌘N
        // is gone since (a hand edit, or a rollback that reset it).
        var keyboard = KeyboardSettings()
        keyboard.unbound = [LimpidShortcutAction.newWorktree.rawValue, "anActionFromANewerBuild"]
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.unbound.isEmpty)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandN)
    }

    @Test func aNewWorktreeBinding_keepsWorking() {
        // The action stays and keeps the person's keys. ⌥⌘N is
        // now Create Worktree Now's default, which gives way, and the
        // notice says so.
        var keyboard = KeyboardSettings()
        keyboard.overrides[LimpidShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.optionCommandN)
        #expect(keyboard.shortcut(for: .newWorktreeNow) == nil)
        #expect(keyboard.migrationNotice?.conflicts == [.newWorktreeNow])
    }

    // MARK: New Workspace… folded into New Worktree…

    /// An earlier build's "New Workspace…" saved its binding under
    /// `newSession`. With New Worktree… free of a choice of its own, the
    /// binding moves to it and ⌘N comes free.
    @Test func aNewWorkspaceBinding_movesToNewWorktree() {
        var keyboard = KeyboardSettings()
        keyboard.overrides["newSession"] = Self.commandF
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.overrides["newSession"] == nil)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.commandF)
        #expect(keyboard.retired.isEmpty)
        // The moved binding holds its keys as before: Find's ⌘F gives way,
        // as it did to New Workspace….
        #expect(keyboard.shortcut(for: .find) == nil)
        #expect(keyboard.migrationNotice?.conflicts == [.find])
    }

    /// Both had a binding: New Worktree…'s own stays, and New Workspace…'s
    /// is kept aside, listed under the action that took it over.
    @Test func bothBound_keepsNewWorktrees_andKeepsNewWorkspacesAside() throws {
        var keyboard = KeyboardSettings()
        keyboard.overrides["newSession"] = Self.commandF
        keyboard.overrides[LimpidShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.shortcut(for: .newWorktree) == Self.optionCommandN)
        #expect(keyboard.retired == ["newSession": Self.commandF])
        let notice = try #require(keyboard.migrationNotice)
        #expect(notice.retired == [.init(rawValue: "newSession", shortcut: Self.commandF)])
        let rows = KeyboardMigrationRows.rows(keyboard, quickTerminalHotKey: nil, locale: Locale(identifier: "ja"))
        #expect(rows.first?.title == "新規ワークツリー…")
        // ⌘F binds nothing while it is kept aside: Find keeps its default.
        #expect(keyboard.shortcut(for: .find) == Self.commandF)
    }

    /// A binding kept aside under the old name already (from an earlier
    /// run that a rollback undid) gives way to the one moved aside now.
    @Test func aNewerNewWorkspaceBinding_replacesTheOneKeptAside() {
        var keyboard = KeyboardSettings()
        keyboard.retired["newSession"] = Self.commandReturn
        keyboard.overrides["newSession"] = Self.commandF
        keyboard.overrides[LimpidShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.retired["newSession"] == Self.commandF)
    }

    /// New Workspace… unassigned: New Worktree… is left without keys too,
    /// unless the person had chosen something for it.
    @Test func anUnassignedNewWorkspace_unassignsNewWorktree_unlessItHasAChoice() {
        var keyboard = KeyboardSettings()
        keyboard.unassigned = ["newSession"]
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.unassigned == [LimpidShortcutAction.newWorktree.rawValue])
        #expect(keyboard.shortcut(for: .newWorktree) == nil)

        var bound = KeyboardSettings()
        bound.unassigned = ["newSession"]
        bound.overrides[LimpidShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        (bound, _) = Self.normalized(bound)
        #expect(bound.unassigned.isEmpty)
        #expect(bound.shortcut(for: .newWorktree) == Self.optionCommandN)
    }

    /// A given-up New Workspace… leaves no trace; New Worktree… gives way
    /// on its own when the keys are taken.
    @Test func aGivenUpNewWorkspace_isForgotten() {
        var keyboard = KeyboardSettings()
        keyboard.unbound = ["newSession"]
        keyboard.overrides[LimpidShortcutAction.newTab.rawValue] = Self.commandN
        (keyboard, _) = Self.normalized(keyboard)
        #expect(keyboard.unbound == [LimpidShortcutAction.newWorktree.rawValue])
    }

    /// The fold leaves nothing under the old name, so a second run, and a
    /// file read back, change nothing more.
    @Test func folding_changesNothingMoreTheSecondTime() throws {
        var keyboard = KeyboardSettings()
        keyboard.overrides["newSession"] = Self.commandF
        keyboard.overrides[LimpidShortcutAction.newWorktree.rawValue] = Self.optionCommandN
        let once = Self.normalized(keyboard)
        let twice = Self.normalized(once.0)
        #expect(twice.0 == once.0)
        let read = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(once.0))
        #expect(Self.normalized(read).0 == once.0)
    }

    /// A schema 1 file (the release before) had no New Workspace…; its New
    /// Worktree… binding stays, and with none, New Worktree… is ⌘N.
    @Test func aSchema1File_keepsItsNewWorktreeBinding_orGetsCommandN() throws {
        let bound = try LimpidSettings.testFileData(version: 1, overrides: ["newWorktree": Self.commandF])
        guard case let .migrated(_, data) = try VersionedDocumentMigrator.settings.migrate(bound) else {
            Issue.record("a schema 1 file is migrated")
            return
        }
        let migrated = try PersistenceCoders.makeDecoder().decode(LimpidSettings.self, from: data)
        #expect(migrated.keyboard.shortcut(for: .newWorktree) == Self.commandF)
        #expect(migrated.keyboard.retired.isEmpty)

        let plain = try LimpidSettings.testFileData(version: 1, overrides: [:])
        guard case let .migrated(_, plainData) = try VersionedDocumentMigrator.settings.migrate(plain) else {
            Issue.record("a schema 1 file is migrated")
            return
        }
        let fresh = try PersistenceCoders.makeDecoder().decode(LimpidSettings.self, from: plainData)
        #expect(fresh.keyboard.shortcut(for: .newWorktree) == Self.commandN)
    }

    @Test func commandReturn_isReservedAndExistingOverrideRetired() throws {
        var keyboard = KeyboardSettings()
        keyboard.overrides[LimpidShortcutAction.find.rawValue] = Self.commandReturn

        (keyboard, _) = Self.normalized(keyboard)

        #expect(keyboard.retired[LimpidShortcutAction.find.rawValue] == Self.commandReturn)
        #expect(keyboard.shortcut(for: .find) == LimpidShortcutAction.find.defaultShortcut)
        #expect(keyboard.validate(Self.commandReturn, for: .find) == .reserved)
        let notice = try #require(keyboard.migrationNotice)
        #expect(notice.retired == [.init(rawValue: "find", shortcut: Self.commandReturn)])
        keyboard.discardRetired("find")
        #expect(keyboard.migrationNotice == nil)
    }

    @Test func aRetiredBinding_whoseDefaultAnotherHolds_leavesTheActionUnbound() {
        // Find's default ⌘F comes back once its ⌘⏎ binding is retired, but
        // the person had put ⌘F on New Tab.
        var keyboard = KeyboardSettings()
        keyboard.overrides[LimpidShortcutAction.find.rawValue] = Self.commandReturn
        keyboard.overrides[LimpidShortcutAction.newTab.rawValue] = Self.commandF

        (keyboard, _) = Self.normalized(keyboard)

        #expect(keyboard.shortcut(for: .find) == nil)
        #expect(keyboard.shortcut(for: .newTab) == Self.commandF)
    }

    @Test func theQuickTerminalHotkey_holdsItsKeys_unlessTheyAreReserved() {
        let (unbound, hotKey) = Self.normalized(KeyboardSettings(), hotKey: Self.commandN)
        #expect(hotKey == Self.commandN)
        #expect(unbound.shortcut(for: .newWorktree) == nil, "Carbon takes the hotkey before the menu")

        let (retired, cleared) = Self.normalized(KeyboardSettings(), hotKey: Self.commandReturn)
        #expect(cleared == nil)
        #expect(retired.retired[KeyboardSettings.quickTerminalHotKeyID] == Self.commandReturn)
    }

    @Test func normalizing_changesNothingMoreTheSecondTime() {
        var keyboard = KeyboardSettings()
        keyboard.overrides[LimpidShortcutAction.newTab.rawValue] = Self.commandN
        keyboard.overrides[LimpidShortcutAction.find.rawValue] = Self.commandReturn
        let once = Self.normalized(keyboard, hotKey: Self.commandReturn)
        let twice = Self.normalized(once.0, hotKey: once.1)
        #expect(twice.0 == once.0)
        #expect(twice.1 == once.1)
    }

    @Test func unboundAndRetiredKeys_reachNoKeybind() {
        var settings = LimpidSettings()
        settings.keyboard.unbound = [LimpidShortcutAction.newWorktree.rawValue]
        settings.keyboard.retired = [LimpidShortcutAction.find.rawValue: Self.commandReturn]
        let config = GhosttyConfigBridge.makeConfigString(settings: settings, resourcesDir: nil)
        #expect(!config.contains("keybind = \(Self.commandN.ghosttyTrigger)="))
        #expect(!config.contains("keybind = \(Self.commandReturn.ghosttyTrigger)="))
    }

    @Test func migration_runsOnceThenVersionIsTwo() throws {
        let v1 = try LimpidSettings.testFileData(version: 1, overrides: ["find": Self.commandReturn])
        guard case let .migrated(from, data) = try VersionedDocumentMigrator.settings.migrate(v1) else {
            Issue.record("a schema 1 file is migrated")
            return
        }
        #expect(from == 1)
        let migrated = try PersistenceCoders.makeDecoder().decode(LimpidSettings.self, from: data)
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.keyboard.retired["find"] == Self.commandReturn)
        #expect(try VersionedDocumentMigrator.settings.migrate(data) == .current)

        // A file from before the version key existed is schema 1.
        var withoutVersion = try #require(JSONSerialization.jsonObject(with: v1) as? [String: Any])
        withoutVersion.removeValue(forKey: "schemaVersion")
        let unversioned = try JSONSerialization.data(withJSONObject: withoutVersion)
        guard case .migrated(from: 1, _) = try VersionedDocumentMigrator.settings.migrate(unversioned) else {
            Issue.record("an unversioned file is schema 1")
            return
        }
    }

    @Test func v2Settings_decodeWithV1Types() throws {
        var keyboard = KeyboardSettings()
        keyboard.overrides["newTab"] = Self.commandN
        keyboard.unbound = ["newWorktree"]
        keyboard.retired = ["find": Self.commandReturn]
        let data = try JSONEncoder().encode(keyboard)

        let old = try JSONDecoder().decode(KeyboardSettingsV1.self, from: data)
        #expect(old.overrides == ["newTab": Self.commandN])
        // The older build saves what it does not know, so a rollback and
        // a return keep the person's notice.
        let roundTripped = try JSONDecoder().decode(KeyboardSettings.self, from: JSONEncoder().encode(old))
        #expect(roundTripped == keyboard)
    }
}
