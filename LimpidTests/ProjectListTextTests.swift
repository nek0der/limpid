// ProjectListTextTests.swift
// Limpid — a list of projects is headed "Projects", and the sidebar's ＋ over it opens a folder on ⌘O.

import Foundation
import Testing
@testable import Limpid

struct ProjectListTextTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test func theHeading_namesTheProjects() {
        #expect(ProjectListText.heading.resolved(in: Self.english) == "Projects")
        #expect(ProjectListText.heading.resolved(in: Self.japanese) == "プロジェクト")
    }

    /// The sidebar heading's ＋ is Open Folder, named as the File menu names
    /// it; a header's ＋ is the one for a new worktree.
    @Test func theSidebarPlus_isOpenFolder_onCommandO() throws {
        let title = LimpidShortcutAction.openFolder.localizedTitle
        let key = try #require(KeyboardSettings().shortcut(for: .openFolder)?.displayString)
        #expect(key == "⌘O")
        #expect(ShortcutHelpText.make(name: title, shortcut: key, locale: Self.english) == "Open Folder… (⌘O)")
        #expect(ShortcutHelpText.make(name: title, shortcut: key, locale: Self.japanese) == "フォルダを開く…（⌘O）")
        #expect(ProjectListText.openFolderLabel.resolved(in: Self.english) == "Open Folder")
        #expect(ProjectListText.openFolderLabel.resolved(in: Self.japanese) == "フォルダを開く")
    }
}
