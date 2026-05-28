// CommandPaletteState.swift
// Limpid — transient state for the command palette overlay.

import Foundation
import Observation

@MainActor
@Observable
final class CommandPaletteState {
    var query: String = ""
    var selectedIndex: Int = 0
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

    /// Single source of truth for filtering + ranking. Called on every
    /// query change and once at open time (with empty query).
    func applyFilter(query: String, frecencyStore: FrecencyStore?) {
        if query.isEmpty {
            results = allItems
                .sorted { (frecencyStore?.score(for: $0.id) ?? 0) > (frecencyStore?.score(for: $1.id) ?? 0) }
                .map { ScoredItem(item: $0, matchedIndices: [], score: 0) }
        } else {
            results = allItems.compactMap { item -> ScoredItem? in
                let titleResult = FuzzyMatch.score(query: query, candidate: item.title)
                let aliasResult = item.searchAlias.flatMap {
                    FuzzyMatch.score(query: query, candidate: $0)
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
