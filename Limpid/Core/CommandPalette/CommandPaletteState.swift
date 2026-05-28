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

        if filterQuery.isEmpty {
            results = candidates
                .sorted { (frecencyStore?.score(for: $0.id) ?? 0) > (frecencyStore?.score(for: $1.id) ?? 0) }
                .map { ScoredItem(item: $0, matchedIndices: [], score: 0) }
        } else {
            results = candidates.compactMap { item -> ScoredItem? in
                let titleResult = FuzzyMatch.score(query: filterQuery, candidate: item.title)
                let aliasResult = item.searchAlias.flatMap {
                    FuzzyMatch.score(query: filterQuery, candidate: $0)
                }
                guard let best = [titleResult, aliasResult]
                    .compactMap(\.self)
                    .max(by: { $0.score < $1.score })
                else { return nil }
                let frecency = (frecencyStore?.score(for: item.id) ?? 0) * 10
                let combined = best.score + Int(frecency)
                let indices = titleResult != nil && titleResult!.score >= (aliasResult?.score ?? 0)
                    ? best.matchedIndices : []
                return ScoredItem(item: item, matchedIndices: indices, score: combined)
            }
            .sorted { $0.score > $1.score }
        }
        selectedIndex = 0
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
