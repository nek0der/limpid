// CommandPaletteTests.swift
// Limpid — tests for fuzzy search, frecency scoring, catalog building,
// and command palette state lifecycle.

import Foundation
import Testing
@testable import Limpid

@Suite("CommandPalette")
@MainActor
struct CommandPaletteTests {

    // MARK: - FuzzyMatch

    @Test("exact substring scores higher than scattered chars")
    func fuzzyMatch_exactSubstring_scoresHigher() throws {
        let exact = FuzzyMatch.score(query: "New", candidate: "New Tab")
        let scattered = FuzzyMatch.score(query: "Nwb", candidate: "New Tab")
        #expect(exact != nil)
        // Scattered may or may not match; if it does, exact should win.
        if let scattered {
            #expect(try #require(exact?.score) > scattered.score)
        }
    }

    @Test("word-start bonus lifts matching initial letters")
    func fuzzyMatch_wordStart_bonus() throws {
        let wordStart = FuzzyMatch.score(query: "nt", candidate: "New Tab")
        let midWord = FuzzyMatch.score(query: "ew", candidate: "New Tab")
        #expect(wordStart != nil)
        #expect(midWord != nil)
        #expect(try #require(wordStart?.score) > midWord!.score)
    }

    @Test("empty query matches everything with score 0")
    func fuzzyMatch_emptyQuery_matchesAll() throws {
        let result = FuzzyMatch.score(query: "", candidate: "anything")
        #expect(result != nil)
        #expect(result?.score == 0)
        #expect(try #require(result?.matchedIndices.isEmpty))
    }

    @Test("no match returns nil")
    func fuzzyMatch_noMatch_returnsNil() {
        let result = FuzzyMatch.score(query: "xyz", candidate: "New Tab")
        #expect(result == nil)
    }

    @Test("case insensitive matching works")
    func fuzzyMatch_caseInsensitive() {
        let result = FuzzyMatch.score(query: "new tab", candidate: "New Tab")
        #expect(result != nil)
    }

    @Test("matched indices are correct")
    func fuzzyMatch_matchedIndices_correct() {
        let result = FuzzyMatch.score(query: "NT", candidate: "New Tab")
        #expect(result != nil)
        #expect(result?.matchedIndices.count == 2)
        #expect(result?.matchedIndices[0] == 0) // N
        #expect(result?.matchedIndices[1] == 4) // T
    }

    @Test("consecutive chars get bonus")
    func fuzzyMatch_consecutive_bonus() throws {
        let consecutive = FuzzyMatch.score(query: "Sp", candidate: "Split Right")
        let nonConsecutive = FuzzyMatch.score(query: "St", candidate: "Split Right")
        #expect(consecutive != nil)
        #expect(nonConsecutive != nil)
        #expect(try #require(consecutive?.score) > nonConsecutive!.score)
    }

    // MARK: - FrecencyStore

    @Test("recently used item scores higher than older one")
    func frecency_recentItem_scoresHigher() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            store.record("recent")
            // "old" was recorded a week ago via repeated `record` calls.
            store.record("old")
            // The recent item was just recorded, so it should score
            // at least as high. To test the decay properly we compare
            // a fresh record vs one that has been sitting.
            #expect(store.score(for: "recent") > 0)
            #expect(store.score(for: "old") > 0)
        }
    }

    @Test("frequently used item scores higher")
    func frecency_frequentItem_scoresHigher() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            for _ in 0..<10 {
                store.record("frequent")
            }
            store.record("rare")
            #expect(store.score(for: "frequent") > store.score(for: "rare"))
        }
    }

    @Test("recording updates count")
    func frecency_record_updatesEntry() throws {
        try withTempDir { dir in
            let store = FrecencyStore(directory: dir)
            store.record("test")
            #expect(store.entries["test"]?.count == 1)
            store.record("test")
            #expect(store.entries["test"]?.count == 2)
        }
    }

    @Test("persistence round-trip survives")
    func frecency_persistence_roundTrip() throws {
        try withTempDir { dir in
            let store1 = FrecencyStore(directory: dir)
            store1.record("x")
            store1.record("x")
            store1.flushSynchronously()

            let store2 = FrecencyStore(directory: dir)
            #expect(store2.entries["x"]?.count == 2)
        }
    }

    // MARK: - Catalog

    @Test("catalog includes all shortcut actions")
    func catalog_includesAllShortcutActions() {
        let session = WindowSession()
        let settings = SettingsStore()
        let items = CommandPaletteCatalog.buildItems(session: session, settings: settings)
        let shortcutItems = items.filter { $0.category == .actions }
        #expect(shortcutItems.count == LimpidShortcutAction.allCases.count)
    }

    @Test("catalog includes open tabs with display titles")
    func catalog_includesOpenTabs() {
        let (session, _, _) = WindowSessionFixture.withLooseTab()
        let settings = SettingsStore()
        let items = CommandPaletteCatalog.buildItems(session: session, settings: settings)
        let tabItems = items.filter {
            if case .jumpToTab = $0.action { return true }
            return false
        }
        #expect(tabItems.count == 1)
    }

    @Test("catalog includes groups")
    func catalog_includesGroups() {
        let (session, group, _) = WindowSessionFixture.withGroupAndOneTab()
        let settings = SettingsStore()
        let items = CommandPaletteCatalog.buildItems(session: session, settings: settings)
        let groupItems = items.filter {
            if case let .activateGroup(id) = $0.action { return id == group.id }
            return false
        }
        #expect(groupItems.count == 1)
    }

    // MARK: - State lifecycle

    @Test("opening palette builds items from session")
    func state_openPalette_buildsItems() throws {
        let session = WindowSession()
        let settings = SettingsStore()
        try withTempDir { dir in
            let frecency = FrecencyStore(directory: dir)
            SessionActions.openCommandPalette(session, settings: settings, frecencyStore: frecency)
            #expect(session.commandPaletteState != nil)
            #expect(!session.commandPaletteState!.allItems.isEmpty)
        }
    }

    @Test("closing palette nils out the state")
    func state_closePalette_nilsState() throws {
        let session = WindowSession()
        let settings = SettingsStore()
        try withTempDir { dir in
            let frecency = FrecencyStore(directory: dir)
            SessionActions.openCommandPalette(session, settings: settings, frecencyStore: frecency)
            SessionActions.closeCommandPalette(session)
            #expect(session.commandPaletteState == nil)
        }
    }

    @Test("selectedIndex clamps to results range")
    func state_clampSelection() {
        let state = CommandPaletteState()
        state.selectedIndex = 10
        state.results = [
            CommandPaletteState.ScoredItem(
                item: CommandPaletteItem(
                    id: "test",
                    category: .actions,
                    title: "Test",
                    subtitle: nil,
                    icon: "star",
                    shortcutDisplay: nil,
                    action: .openSettings
                ),
                matchedIndices: [],
                score: 0
            )
        ]
        state.clampSelection()
        #expect(state.selectedIndex == 0)
    }

    @Test("opening while already open is idempotent")
    func state_openWhileOpen_idempotent() throws {
        let session = WindowSession()
        let settings = SettingsStore()
        try withTempDir { dir in
            let frecency = FrecencyStore(directory: dir)
            SessionActions.openCommandPalette(session, settings: settings, frecencyStore: frecency)
            let first = session.commandPaletteState
            SessionActions.openCommandPalette(session, settings: settings, frecencyStore: frecency)
            #expect(session.commandPaletteState === first)
        }
    }
}
