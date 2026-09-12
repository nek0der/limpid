// SettingsSearchIndexTests.swift
// Limpid — matching and ordering coverage for Settings search.

import Foundation
import Testing
@testable import Limpid

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
            ("PR", "integrations.pr-status"),
            ("gh", "integrations.pr-status"),
            ("glab", "integrations.pr-status")
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
