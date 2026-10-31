// SettingsSearchTests.swift
// Weir — Settings search: its catalog of destinations, matching and ordering, and keyboard navigation.

import Foundation
import Testing
@testable import Weir

@Suite("SettingsSearchCatalog")
struct SettingsSearchCatalogTests {
    @Test("Every entry has a unique ID")
    func entries_haveUniqueIDs() {
        let ids = SettingsSearchCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every shortcut action has one search entry")
    func entries_includeEveryShortcutAction() {
        let ids = Set(SettingsSearchCatalog.entries.map(\.id))
        for action in WeirShortcutAction.allCases {
            #expect(ids.contains("keyboard.shortcut.\(action.rawValue)"))
        }
    }

    @Test("Entries cover every Settings category")
    func entries_coverEverySection() {
        let sections = Set(SettingsSearchCatalog.entries.map(\.section))
        #expect(sections == Set(SettingsSection.allCases))
    }

    @Test("Entries retain a stable order inside each category")
    func entries_haveUniqueOrdersWithinSections() {
        for section in SettingsSection.allCases {
            let orders = SettingsSearchCatalog.entries
                .filter { $0.section == section }
                .map(\.order)
            #expect(Set(orders).count == orders.count, "duplicate order in \(section.rawValue)")
        }
    }

    @Test("Major settings and actions are indexed")
    func entries_includeMajorSettingsAndActions() {
        let ids = Set(SettingsSearchCatalog.entries.map(\.id))
        let expected = [
            "general.display-language",
            "appearance.theme",
            "font.family",
            "terminal.scrollback",
            "tabs-and-panes.minimum-pane-size",
            "integrations.ghostty-config",
            "review.instructions",
            "advanced.restore-all-defaults"
        ]
        for id in expected {
            #expect(ids.contains(id), "missing \(id)")
        }
    }
}

@Suite("SettingsSearchIndex")
struct SettingsSearchIndexTests {
    private let english = Locale(identifier: "en")
    private let japanese = Locale(identifier: "ja")

    @Test("Blank queries have no results")
    func search_blankQuery_returnsNoResults() {
        let index = SettingsSearchIndex(locale: english)
        #expect(index.search(" \n\t ").isEmpty)
    }

    @Test("English and Japanese localized labels match")
    func search_localizedLabels_matches() {
        let englishIndex = SettingsSearchIndex(locale: english)
        let japaneseIndex = SettingsSearchIndex(locale: japanese)

        #expect(englishIndex.search("scrollback").contains { $0.id == "terminal.scrollback" })
        #expect(japaneseIndex.search("スクロールバック").contains { $0.id == "terminal.scrollback" })
    }

    @Test("English fallback remains searchable in Japanese")
    func search_englishFallback_matchesInJapanese() {
        let index = SettingsSearchIndex(locale: japanese)
        #expect(index.search("cursor blink").contains { $0.id == "terminal.cursor-blink" })
    }

    @Test("Technical aliases match")
    func search_technicalAliases_matches() {
        let index = SettingsSearchIndex(locale: english)
        let expectations = [
            ("json", "advanced.reveal-settings-file"),
            ("Ghostty", "integrations.ghostty-config"),
            ("tmux", "integrations.tmux"),
            ("Retention", "advanced.turn-retention-days"),
            ("Scratch directory", "tabs-and-panes.default-working-directory"),
            ("Diff tool", "review.external-diff-command")
        ]
        for (query, id) in expectations {
            #expect(index.search(query).contains { $0.id == id }, "missing \(id) for \(query)")
        }
    }

    @Test("Every query token must match")
    func search_multipleTokens_requiresAllTokens() {
        let index = SettingsSearchIndex(locale: english)
        let ids = Set(index.search("cursor tmux").map(\.id))
        #expect(ids.isEmpty)
    }

    @Test("Exact, prefix, substring, and keyword matches are ranked")
    func search_ranksMatchesByRelevance() {
        let entries = [
            SettingsSearchEntry(id: "keyword", section: .general, groupTitle: "General", title: "Option", keywords: ["display"], order: 0),
            SettingsSearchEntry(id: "substring", section: .general, groupTitle: "General", title: "Show display options", order: 1),
            SettingsSearchEntry(id: "prefix", section: .general, groupTitle: "General", title: "Display language", order: 2),
            SettingsSearchEntry(id: "exact", section: .general, groupTitle: "General", title: "Display", order: 3)
        ]
        let index = SettingsSearchIndex(entries: entries, locale: english)
        #expect(index.search("display").map(\.id) == ["exact", "prefix", "substring", "keyword"])
    }

    @Test("Equal results follow category then display order")
    func search_equalScores_areStable() {
        let entries = [
            SettingsSearchEntry(id: "terminal", section: .terminal, groupTitle: "History", title: "Item", keywords: ["match"], order: 0),
            SettingsSearchEntry(
                id: "general-later",
                section: .general,
                groupTitle: "General",
                title: "Item",
                keywords: ["match"],
                order: 2
            ),
            SettingsSearchEntry(id: "general-first", section: .general, groupTitle: "General", title: "Item", keywords: ["match"], order: 1)
        ]
        let index = SettingsSearchIndex(entries: entries, locale: english)
        #expect(index.search("match").map(\.id) == ["general-first", "general-later", "terminal"])
    }

    @Test("Category order matches the grouped result list before relevance")
    func search_categoryOrder_matchesGroupedResults() {
        let entries = [
            SettingsSearchEntry(
                id: "terminal-exact",
                section: .terminal,
                groupTitle: "Terminal",
                title: "Match",
                order: 0
            ),
            SettingsSearchEntry(
                id: "general-keyword",
                section: .general,
                groupTitle: "General",
                title: "Option",
                keywords: ["match"],
                order: 0
            )
        ]
        let index = SettingsSearchIndex(entries: entries, locale: english)
        #expect(index.search("match").map(\.id) == ["general-keyword", "terminal-exact"])
    }
}

@Suite("SettingsSearchNavigation")
struct SettingsSearchNavigationTests {
    private let results = [
        SettingsSearchEntry(id: "first", section: .general, groupTitle: "General", title: "First", order: 0),
        SettingsSearchEntry(id: "second", section: .general, groupTitle: "General", title: "Second", order: 1)
    ]

    @Test("Arrow selection starts at the nearest end and clamps")
    func movedSelection_startsAndClamps() {
        #expect(SettingsSearchNavigation.movedSelection(from: nil, by: 1, in: results) == "first")
        #expect(SettingsSearchNavigation.movedSelection(from: nil, by: -1, in: results) == "second")
        #expect(SettingsSearchNavigation.movedSelection(from: "first", by: -1, in: results) == "first")
        #expect(SettingsSearchNavigation.movedSelection(from: "second", by: 1, in: results) == "second")
    }

    @Test("Submission uses the selection and otherwise falls back to the first result")
    func submittedEntry_usesSelectionOrFirst() {
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: "second", in: results)?.id == "second")
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: nil, in: results)?.id == "first")
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: "missing", in: results)?.id == "first")
        #expect(SettingsSearchNavigation.submittedEntry(selectedID: nil, in: []) == nil)
    }
}
