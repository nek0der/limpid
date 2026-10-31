// KeyboardKeyIntroductionTests.swift
// Weir — ⌥⌘N after an update from the release where it was the sheet: the sheet once more, saying what the keys do now, and never again.

import Foundation
import Testing
@testable import Weir

@MainActor
struct KeyboardKeyIntroductionTests {
    private static let optionCommandN = TestShortcuts.optionCommandN
    private static let commandF = TestShortcuts.commandF

    /// The keyboard as a schema 1 file leaves the move: its bindings moved,
    /// then the keys whose meaning changed noted.
    private static func moved(_ schema1: KeyboardSettings) -> KeyboardSettings {
        var keyboard = schema1.normalizedForTest().keyboard
        keyboard.noteChangedKeys(since: schema1)
        return keyboard
    }

    // MARK: - Who is told

    /// The previous release's ⌥⌘N was the sheet, and is Create Worktree Now
    /// now: the person is told on their first ⌥⌘N.
    @Test func aSchema1File_onTheDefaults_isToldOnce() {
        let keyboard = Self.moved(KeyboardSettings())

        #expect(keyboard.shortcut(for: .newWorktreeNow) == Self.optionCommandN)
        #expect(keyboard.isIntroductionDue(for: .newWorktreeNow))
        #expect(KeyboardSettings.schema1NewWorktreeDefault == Self.optionCommandN)
    }

    /// Their own keys for New Worktree… meant ⌥⌘N was never the sheet.
    @Test func aSchema1File_withItsOwnKeysForNewWorktree_isNotTold() {
        var schema1 = KeyboardSettings()
        schema1.overrides["newWorktree"] = Self.commandF

        #expect(!Self.moved(schema1).isIntroductionDue(for: .newWorktreeNow))
    }

    /// New Worktree… bound to ⌥⌘N in the file, the default written out,
    /// keeps those keys: the sheet stays on them, Create Worktree Now has
    /// none, and nothing changed under the person's hands.
    @Test func aSchema1File_withOptionCommandNWrittenOutForNewWorktree_isNotTold() {
        var schema1 = KeyboardSettings()
        schema1.overrides["newWorktree"] = Self.optionCommandN
        let keyboard = Self.moved(schema1)

        #expect(keyboard.shortcut(for: .newWorktree) == Self.optionCommandN)
        #expect(keyboard.shortcut(for: .newWorktreeNow) == nil)
        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// Bound to other keys since, Create Worktree Now has nothing to say:
    /// the person chose them knowing what they do.
    @Test func keysBoundSince_haveNothingToSay() {
        var keyboard = Self.moved(KeyboardSettings())
        keyboard.setOverride(Self.commandF, for: .newWorktreeNow)

        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// Their own binding on ⌥⌘N keeps it theirs: Create Worktree Now starts
    /// with no keys, and nothing changed under their hands.
    @Test func aSchema1File_withAnotherActionOnOptionCommandN_isNotTold() {
        var schema1 = KeyboardSettings()
        schema1.overrides["newWorktree"] = Self.commandF
        schema1.overrides["newTab"] = Self.optionCommandN
        let keyboard = Self.moved(schema1)

        #expect(keyboard.shortcut(for: .newWorktreeNow) == nil)
        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// The quick terminal's hotkey on ⌥⌘N holds it the same way.
    @Test func aSchema1File_withTheHotKeyOnOptionCommandN_isNotTold() {
        let schema1 = KeyboardSettings()
        var (keyboard, _) = schema1.normalizedForTest(hotKey: Self.optionCommandN)
        keyboard.noteChangedKeys(since: schema1)

        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// Noting twice lists it once.
    @Test func notingTwice_listsItOnce() {
        var keyboard = Self.moved(KeyboardSettings())
        keyboard.noteChangedKeys(since: KeyboardSettings())

        #expect(keyboard.keysToIntroduce == ["newWorktreeNow"])
    }

    // MARK: - Said, then kept

    /// Once said, it is not due again, and loads and changes leave it so.
    @Test func onceSaid_itIsNotDueAgain() {
        var keyboard = Self.moved(KeyboardSettings())
        keyboard.markIntroduced(.newWorktreeNow)
        var hotKey: StoredShortcut?
        keyboard.normalize(quickTerminalHotKey: &hotKey)

        #expect(!keyboard.isIntroductionDue(for: .newWorktreeNow))
    }

    /// Kept through the file, and written only while there is something to
    /// say, so a file that never needed it reads as it did.
    @Test func theList_roundTripsThroughTheFile_andIsLeftOutWhenEmpty() throws {
        var settings = WeirSettings()
        settings.keyboard = Self.moved(KeyboardSettings())
        let data = try WeirSettings.makeFileEncoder().encode(settings)
        let decoded = try PersistenceCoders.makeDecoder().decode(WeirSettings.self, from: data)
        #expect(decoded.keyboard.isIntroductionDue(for: .newWorktreeNow))

        settings.keyboard.markIntroduced(.newWorktreeNow)
        let emptied = try String(bytes: WeirSettings.makeFileEncoder().encode(settings), encoding: .utf8) ?? ""
        #expect(!emptied.contains("keysToIntroduce"))
    }

    // MARK: - Through the store

    @Test func theStore_movingASchema1File_tellsOnce_andRecordsItSaid() throws {
        try withTempDir { dir in
            try WeirSettings.testFileData(version: 1, overrides: [:]).write(to: dir.appendingPathComponent("settings.json"))
            let store = SettingsStore(directory: dir)
            #expect(store.settings.keyboard.isIntroductionDue(for: .newWorktreeNow))

            store.settings.keyboard.markIntroduced(.newWorktreeNow)
            store.saveNow()

            #expect(!SettingsStore(directory: dir).settings.keyboard.isIntroductionDue(for: .newWorktreeNow))
        }
    }

    /// A new person's ⌥⌘N, and the builds of this release, were never the
    /// sheet: nothing to say.
    @Test func noFile_orASchema2File_tellsNothing() throws {
        try withTempDir { dir in
            #expect(!SettingsStore(directory: dir).settings.keyboard.isIntroductionDue(for: .newWorktreeNow))
        }
        try withTempDir { dir in
            try WeirSettings.testFileData(version: 2, overrides: [:]).write(to: dir.appendingPathComponent("settings.json"))
            #expect(!SettingsStore(directory: dir).settings.keyboard.isIntroductionDue(for: .newWorktreeNow))
        }
    }

    // MARK: - ⌥⌘N in the window

    /// Due, ⌥⌘N opens the sheet saying what the keys do now, instead of
    /// making a worktree.
    @Test func optionCommandN_whileDue_opensTheSheetWithTheNote() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        session.setActiveContainer(.project(project.id))
        let window = ProjectWindowState(selection: session.primarySelection)
        let keyboard = Self.moved(KeyboardSettings())

        #expect(SupervisionWindowActions.introduceInstantWorktree(in: window, keyboard: keyboard))

        #expect(window.newSession?.projectID == project.id)
        #expect(window.newWorktreeSheet.introducesInstantKey)
    }

    /// Said, or never due, ⌥⌘N is left to make the worktree; and a window
    /// that shows no project has nothing to open it for.
    @Test func optionCommandN_notDue_orWithNoProject_leavesTheSheetClosed() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        session.setActiveContainer(.project(project.id))
        let window = ProjectWindowState(selection: session.primarySelection)
        #expect(!SupervisionWindowActions.introduceInstantWorktree(in: window, keyboard: KeyboardSettings()))
        #expect(window.newSession == nil)

        let empty = ProjectWindowState(selection: WindowSelection())
        #expect(!SupervisionWindowActions.introduceInstantWorktree(in: empty, keyboard: Self.moved(KeyboardSettings())))
        #expect(empty.newSession == nil)
    }

    // MARK: - The note

    @Test func theNote_namesTheKeysAsBoundNow() {
        let en = Locale(identifier: "en")
        let commandN = TestShortcuts.commandN
        #expect(InstantWorktreeKeyText.note(now: Self.optionCommandN, sheet: commandN).resolved(in: en)
            == "\(Self.optionCommandN.displayString) now creates a worktree without showing this sheet. "
            + "This sheet now opens with \(commandN.displayString).")
        #expect(InstantWorktreeKeyText.note(now: Self.optionCommandN, sheet: nil).resolved(in: en).hasSuffix("in the File menu."))
        #expect(InstantWorktreeKeyText.note(now: nil, sheet: commandN).resolved(in: en).hasPrefix("Create Worktree Now"))
        let ja = InstantWorktreeKeyText.note(now: Self.optionCommandN, sheet: commandN).resolved(in: Locale(identifier: "ja"))
        #expect(ja == "\(Self.optionCommandN.displayString) は、このシートを表示せずにワークツリーを作成するようになりました。このシートは \(commandN.displayString) で開きます。")
    }
}
