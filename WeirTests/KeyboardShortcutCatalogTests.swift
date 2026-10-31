// KeyboardShortcutCatalogTests.swift
// Weir — the cheat sheet's row source. The sheet itself is plain
// SwiftUI over these sections, so the coverage that matters is here:
// every action is listed, user overrides win over defaults, search
// hits both the label and the glyph form, and the ⌘/ default does not
// collide with any other binding.

import Foundation
import Testing
@testable import Weir

@Suite("KeyboardShortcutCatalog")
@MainActor
struct KeyboardShortcutCatalogTests {

    private func sections(
        keyboard: KeyboardSettings = KeyboardSettings(),
        quickTerminalHotKey: StoredShortcut? = nil,
        locale: Locale = Locale(identifier: "en")
    ) -> [KeyboardShortcutSection] {
        KeyboardShortcutCatalog.sections(keyboard: keyboard, quickTerminalHotKey: quickTerminalHotKey, locale: locale)
    }

    private func entries(_ sections: [KeyboardShortcutSection]) -> [KeyboardShortcutEntry] {
        sections.flatMap(\.entries)
    }

    @Test("Every action with keys appears exactly once, and one without none")
    func sections_coverEveryAction() {
        let ids = entries(sections()).map(\.id)
        let keyboard = KeyboardSettings()
        for action in WeirShortcutAction.allCases {
            // A sheet of keys has nothing to say for an action with none
            // (Go Back, Go Forward, New Window by default).
            let expected = keyboard.shortcut(for: action) == nil ? 0 : 1
            #expect(ids.filter { $0 == "action.\(action.rawValue)" }.count == expected, "\(action.rawValue)")
        }
    }

    @Test("Sections follow category order and never render empty")
    func sections_orderAndNonEmpty() {
        let all = sections()
        let categoryIDs = WeirShortcutCategory.allCases.map { "category.\($0.rawValue)" }
        let present = all.map(\.id).filter { categoryIDs.contains($0) }
        #expect(present == categoryIDs.filter { id in all.contains { $0.id == id } })
        #expect(all.allSatisfy { !$0.entries.isEmpty })
    }

    @Test("A user override shows the rebound keys, not the default")
    func sections_reflectOverride() {
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.newTab.rawValue] = StoredShortcut(key: "n", modifiers: [.command, .control])
        let row = entries(sections(keyboard: keyboard)).first { $0.id == "action.newTab" }
        #expect(row?.tokens == ["⌃", "⌘", "N"])
    }

    @Test("Reserved jumps and the forced newline keybind are listed")
    func sections_includeFixedRows() {
        let ids = Set(entries(sections()).map(\.id))
        #expect(ids.contains("fixed.goToTab"))
        #expect(ids.contains("fixed.goToWorktree"))
        #expect(ids.contains("fixed.insertNewline"))
        #expect(ids.contains("fixed.settings"))
    }

    @Test func theSheet_listsTheCommandClick_inAWindowSection() throws {
        let window = try #require(sections(locale: Locale(identifier: "ja")).first { $0.id == "fixed.window" })
        // ⌘-click has no key to bind, so the sheet is where it is found.
        #expect(window.title == "ウインドウ")
        #expect(window.entries.map(\.title) == ["新規ウインドウで開く"])
        #expect(window.entries.map(\.tokens) == [["⌘", "クリック"]])
        #expect(window.entries.first?.searchAliases.contains("Open in New Window") == true)
        let english = try #require(sections().first { $0.id == "fixed.window" })
        #expect(english.title == "Window")
        #expect(english.entries.map(\.tokens) == [["⌘", "Click"]])
    }

    @Test func theSheet_namesTheNumberKeys_tabsAndWorktrees() throws {
        let numbers = try #require(sections(locale: Locale(identifier: "ja")).first { $0.id == "fixed.tabsAndWorktrees" })
        // ⌃⌘1–9 goes to the nth working worktree the sidebar shows.
        #expect(numbers.title == "タブとワークツリー")
        #expect(numbers.entries.map(\.title) == ["タブ 1〜9 へ移動", "ワークツリー 1〜9 へ移動"])
        #expect(numbers.entries.map(\.tokens) == [["⌘", "1–9"], ["⌃", "⌘", "1–9"]])
        #expect(numbers.entries.last?.searchAliases.contains("Go to Worktree 1–9") == true)
        // ⌘[ ⌘] are listed under the same word.
        let navigation = try #require(sections().first { $0.id == "category.\(WeirShortcutCategory.navigation.rawValue)" })
        let titles = navigation.entries.map(\.title)
        #expect(titles.contains("Next Worktree"))
        #expect(titles.contains("Previous Worktree"))
    }

    @Test("The palette's restore entry is listed under the palette's keys")
    func sections_listThePalettesRestoreEntry() throws {
        let view = try #require(sections(locale: Locale(identifier: "ja"))
            .first { $0.id == "category.\(WeirShortcutCategory.view.rawValue)" })
        let restore = try #require(view.entries.first { $0.id == "palette.restoreTurn" })
        #expect(restore.title == "このターンの前にコードを復元…")
        #expect(restore.tokens == KeyboardSettings().shortcut(for: .commandPalette)?.displayTokens)
    }

    @Test("The review's diff keys are listed, as the review tab writes no keys along its foot")
    func sections_listTheReviewKeys() throws {
        let review = try #require(sections(locale: Locale(identifier: "ja")).first { $0.id == "fixed.review" })
        #expect(review.title == "レビュー")
        #expect(review.entries.map(\.tokens) == [
            ["J"], ["K"], ["⇧", "J"], ["⇧", "K"], ["]"], ["["], ["H"], ["L"], ["N"], ["P"], ["C"], ["V"], ["O"]
        ])
        let nextHunk = try #require(review.entries.first { $0.id == "review.nextHunk" })
        #expect(nextHunk.title == "次のハンク")
        // Found by its English name in Japanese too.
        #expect(nextHunk.searchAliases.contains("Next Hunk"))
    }

    @Test("The sheet and the diff name the same review keys")
    func reviewKeys_areTheSameInTheSheetAndTheDiff() throws {
        let review = try #require(sections().first { $0.id == "fixed.review" })
        // As the table receives them: a letter lower case, with ⇧ upper case.
        let listed = review.entries.map { entry -> String in
            let key = entry.tokens.last ?? ""
            return entry.tokens.contains("⇧") ? key.uppercased() : key.lowercased()
        }
        let answered = Set(ReviewTableKey.byCharacter.keys)

        #expect(Set(listed) == answered)
        #expect(listed.count == answered.count, "one row per key")
    }

    @Test("Quick terminal hotkey is listed only when one is set")
    func sections_quickTerminalHotKey() {
        #expect(!sections().contains { $0.id == "fixed.systemWide" })
        let hotKey = StoredShortcut(key: "`", modifiers: [.control])
        let row = entries(sections(quickTerminalHotKey: hotKey)).first { $0.id == "fixed.quickTerminal" }
        #expect(row?.tokens == ["⌃", "`"])
    }

    @Test("Search matches the label and drops sections left empty")
    func filter_matchesLabel() {
        let filtered = KeyboardShortcutCatalog.filter(sections(), query: "split right")
        #expect(filtered.count == 1)
        #expect(filtered.first?.entries.map(\.id) == ["action.splitRight"])
    }

    @Test("Search matches the glyph form in HIG order and with ⌘ first")
    func filter_matchesGlyphs() {
        for query in ["⇧⌘T", "⌘⇧T"] {
            let filtered = KeyboardShortcutCatalog.filter(sections(), query: query)
            let ids = entries(filtered).map(\.id)
            #expect(ids.contains("action.reopenClosedTab"), "query \(query)")
        }
    }

    @Test("Empty or whitespace query returns everything")
    func filter_emptyQuery() {
        let all = sections()
        #expect(KeyboardShortcutCatalog.filter(all, query: "") == all)
        #expect(KeyboardShortcutCatalog.filter(all, query: "   ") == all)
    }

    @Test("No match yields no sections rather than bare headers")
    func filter_noMatch() {
        #expect(KeyboardShortcutCatalog.filter(sections(), query: "zzzzqqqq").isEmpty)
    }

    @Test func newWindow_hasNoDefaultKeys_andIsAFileMenuItem() {
        // ⌘N is New Worktree… and ⇧⌘N the notification history.
        #expect(WeirShortcutAction.newWindow.defaultShortcut == nil)
        #expect(WeirShortcutAction.newWindow.category == .file)
        #expect(WeirShortcutAction.newWindow.ghosttyAction == nil)
        #expect(!entries(sections()).contains { $0.id == "action.newWindow" })
        // Bound by the person, the sheet lists it.
        var keyboard = KeyboardSettings()
        keyboard.overrides[WeirShortcutAction.newWindow.rawValue] = StoredShortcut(key: "n", modifiers: [.command, .control, .option])
        #expect(entries(sections(keyboard: keyboard)).contains { $0.id == "action.newWindow" })
    }
}
