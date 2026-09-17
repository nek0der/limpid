// CommandPaletteState.swift
// Limpid — transient state for the command palette overlay.

import Foundation
import Observation

@MainActor
@Observable
final class CommandPaletteState {
    var query: String = ""
    var selectedIndex: Int = 0
    /// Deferred initial query. Set before the view mounts so
    /// `onAppear` can apply it after the TextField is ready,
    /// avoiding the full-text-selection that comes from setting
    /// the value before mount.
    var initialQuery: String?
    var results: [ScoredItem] = []
    var allItems: [CommandPaletteItem] = []

    struct ScoredItem: Identifiable, Equatable {
        let item: CommandPaletteItem
        let matchedIndices: [Int]
        let score: Int

        var id: String {
            item.id
        }
    }

    /// The active prefix mode, derived from the current query.
    var activePrefix: PalettePrefix? {
        PalettePrefix.from(query).prefix
    }

    /// Placeholder text for the search field, changes per mode.
    var placeholder: LocalizedStringResource {
        activePrefix?.placeholder ?? "Type a command or search..."
    }

    /// Single source of truth for filtering + ranking. Called on every
    /// query change and once at open time (with empty query).
    func applyFilter(query: String, frecencyStore: FrecencyStore?) {
        let (prefix, filterQuery) = PalettePrefix.from(query)

        // Help mode: show all available prefixes.
        if prefix == .help {
            results = PalettePrefix.allCases.map { mode in
                ScoredItem(
                    item: CommandPaletteItem(
                        id: "help.\(mode.character)",
                        category: .actions,
                        title: String(mode.character),
                        subtitle: String(localized: mode.description),
                        icon: "questionmark.circle",
                        shortcutDisplay: nil,
                        action: .insertPrefix(mode)
                    ),
                    matchedIndices: [],
                    score: 0
                )
            }
            selectedIndex = 0
            return
        }

        // Filter items by prefix category.
        let candidates: [CommandPaletteItem] = if let prefix {
            allItems.filter { prefix.matchesItem($0) }
        } else {
            allItems
        }

        // Ranked within each category, because the dropdown draws one
        // section per category and `selectedIndex` must name the row the
        // user sees highlighted.
        if filterQuery.isEmpty {
            results = candidates
                .sorted {
                    if $0.category != $1.category {
                        return $0.category < $1.category
                    }
                    return (frecencyStore?.score(for: $0.id) ?? 0) > (frecencyStore?.score(for: $1.id) ?? 0)
                }
                .map { ScoredItem(item: $0, matchedIndices: [], score: 0) }
        } else {
            results = candidates.compactMap { item -> ScoredItem? in
                let titleResult = FuzzyMatch.score(query: filterQuery, candidate: item.title)
                let aliasResult = item.searchAlias.flatMap {
                    FuzzyMatch.score(query: filterQuery, candidate: $0)
                }
                let keywordResults = item.searchKeywords.compactMap {
                    FuzzyMatch.score(query: filterQuery, candidate: $0)
                }
                guard let best = ([titleResult, aliasResult].compactMap(\.self) + keywordResults)
                    .max(by: { $0.score < $1.score })
                else { return nil }
                let frecency = (frecencyStore?.score(for: item.id) ?? 0) * 10
                let combined = best.score + Int(frecency)
                // Only title matches are highlighted. Keywords are left out
                // of the comparison: they usually repeat the title's words
                // and would otherwise hide a match the title really has.
                let aliasScore = aliasResult?.score ?? 0
                let indices = titleResult.flatMap { $0.score >= aliasScore ? $0.matchedIndices : nil } ?? []
                return ScoredItem(item: item, matchedIndices: indices, score: combined)
            }
            .sorted(by: Self.displayOrder)
        }
        selectedIndex = 0
    }

    /// Add rows that were listed after the palette opened, and rank them
    /// against the query the field holds now. The highlighted row stays
    /// highlighted when it is still listed, so a late arrival does not move
    /// the selection under the user.
    func mergeItems(_ items: [CommandPaletteItem], frecencyStore: FrecencyStore?) {
        guard !items.isEmpty else { return }
        let selectedID = results.indices.contains(selectedIndex) ? results[selectedIndex].id : nil
        allItems.append(contentsOf: items)
        applyFilter(query: query, frecencyStore: frecencyStore)
        if let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        }
    }

    private static func displayOrder(_ lhs: ScoredItem, _ rhs: ScoredItem) -> Bool {
        if lhs.item.category != rhs.item.category {
            return lhs.item.category < rhs.item.category
        }
        return lhs.score > rhs.score
    }

    func clampSelection() {
        if results.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, results.count - 1)
        }
    }

    func moveSelection(up: Bool) {
        if up {
            selectedIndex = max(0, selectedIndex - 1)
        } else {
            selectedIndex = min(results.count - 1, selectedIndex + 1)
        }
    }
}
