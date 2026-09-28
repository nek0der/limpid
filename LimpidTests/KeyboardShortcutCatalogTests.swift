// KeyboardShortcutCatalogTests.swift
// Limpid — the cheat sheet's row source. The sheet itself is plain
// SwiftUI over these sections, so the coverage that matters is here:
// every action is listed, user overrides win over defaults, search
// hits both the label and the glyph form, and the ⌘/ default does not
// collide with any other binding.

import Foundation
import Testing
@testable import Limpid

@Suite("KeyboardShortcutCatalog")
@MainActor
struct KeyboardShortcutCatalogTests {

    private func sections(
        keyboard: KeyboardSettings = KeyboardSettings(),
        quickTerminalHotKey: StoredShortcut? = nil
    ) -> [KeyboardShortcutSection] {
        KeyboardShortcutCatalog.sections(keyboard: keyboard, quickTerminalHotKey: quickTerminalHotKey)
    }

    private func entries(_ sections: [KeyboardShortcutSection]) -> [KeyboardShortcutEntry] {
        sections.flatMap(\.entries)
    }

    @Test("Every rebindable action appears exactly once")
    func sections_coverEveryAction() {
        let ids = entries(sections()).map(\.id)
        for action in LimpidShortcutAction.allCases {
            #expect(ids.filter { $0 == "action.\(action.rawValue)" }.count == 1, "\(action.rawValue)")
        }
    }

    @Test("Sections follow category order and never render empty")
    func sections_orderAndNonEmpty() {
        let all = sections()
        let categoryIDs = LimpidShortcutCategory.allCases.map { "category.\($0.rawValue)" }
        let present = all.map(\.id).filter { categoryIDs.contains($0) }
        #expect(present == categoryIDs.filter { id in all.contains { $0.id == id } })
        #expect(all.allSatisfy { !$0.entries.isEmpty })
    }

    @Test("A user override shows the rebound keys, not the default")
    func sections_reflectOverride() {
        var keyboard = KeyboardSettings()
        keyboard.overrides[LimpidShortcutAction.newTab.rawValue] = StoredShortcut(key: "n", modifiers: [.command, .control])
        let row = entries(sections(keyboard: keyboard)).first { $0.id == "action.newTab" }
        #expect(row?.tokens == ["⌃", "⌘", "N"])
    }

    @Test("Reserved jumps and the forced newline keybind are listed")
    func sections_includeFixedRows() {
        let ids = Set(entries(sections()).map(\.id))
        #expect(ids.contains("fixed.goToTab"))
        #expect(ids.contains("fixed.goToSection"))
        #expect(ids.contains("fixed.insertNewline"))
        #expect(ids.contains("fixed.settings"))
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

    @Test("Dispatching the action posts the toggle notification for its session")
    func dispatch_postsToggleNotification() {
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        let flag = NotificationFlag()
        var poster: AnyObject?
        let token = NotificationCenter.default.addObserver(
            forName: .limpidToggleKeyboardShortcuts,
            object: nil,
            queue: nil
        ) { note in
            // The observer runs synchronously on the posting thread, so
            // reading the sender here is safe; the flag is what the test
            // asserts on after the call returns.
            poster = note.object as AnyObject?
            flag.fire()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        TabActions.dispatchShortcutAction(
            .keyboardShortcuts,
            session: session,
            attention: AttentionState(),
            registry: RecordingSurfaceRegistry(),
            trackers: TabActions.SessionTrackers(projection: nil),
            toastCenter: ToastCenter(),
            minPaneSize: 0
        )

        #expect(flag.didFire)
        #expect(poster === session)
    }

    @Test("⌘/ default does not collide with any other binding")
    func defaultShortcut_isConflictFree() throws {
        let keyboard = KeyboardSettings()
        let shortcut = try #require(LimpidShortcutAction.keyboardShortcuts.defaultShortcut)
        #expect(keyboard.validate(shortcut, for: .keyboardShortcuts, quickTerminalHotKey: nil) == .ok)
    }
}
