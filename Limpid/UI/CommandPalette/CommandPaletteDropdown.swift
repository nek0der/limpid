// CommandPaletteDropdown.swift
// Limpid — glass-backed results list for the command palette.
// Positioned by ContentView via PreferenceKey; this view only
// renders the scrollable result list.

import SwiftUI

struct CommandPaletteDropdown: View {
    @Bindable var state: CommandPaletteState
    let onDismiss: () -> Void

    var body: some View {
        // Outer vertical padding shortens the inner `ScrollView`, which
        // shortens its legacy scroller track in turn — that's what
        // keeps the track from running flush into the palette's rounded
        // top + bottom corners. Clip BEFORE the glass treatment so the
        // scroller (track + thumb) is bounded by the rounded shape too.
        resultsList
            .padding(.vertical, 10)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .limpidGlass(.palette)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.20), lineWidth: 0.5)
            )
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let grouped = groupedResults()
                    if grouped.isEmpty, !state.query.isEmpty {
                        emptyState
                    } else {
                        ForEach(grouped, id: \.category) { section in
                            sectionHeader(section.category)
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { offset, scored in
                                let gi = globalIndex(
                                    for: offset,
                                    in: section.category,
                                    allSections: grouped
                                )
                                CommandPaletteRow(
                                    item: scored.item,
                                    isSelected: gi == state.selectedIndex,
                                    matchedIndices: scored.matchedIndices,
                                    onTap: { execute(scored.item.action) }
                                )
                                .id(scored.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard newIndex >= 0, newIndex < state.results.count else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(state.results[newIndex].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        Text("No results")
            .font(LimpidFont.bodySecondary)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }

    private func sectionHeader(_ category: CommandPaletteCategory) -> some View {
        Text(category.localizedTitle)
            .font(LimpidFont.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Grouping

    private struct Section {
        let category: CommandPaletteCategory
        let items: [CommandPaletteState.ScoredItem]
    }

    private func groupedResults() -> [Section] {
        Dictionary(grouping: state.results) { $0.item.category }
            .map { Section(category: $0.key, items: $0.value) }
            .sorted { $0.category < $1.category }
    }

    private func globalIndex(for offset: Int, in category: CommandPaletteCategory, allSections: [Section]) -> Int {
        var index = 0
        for section in allSections {
            if section.category == category { return index + offset }
            index += section.items.count
        }
        return index + offset
    }

    private func execute(_ action: CommandPaletteAction) {
        NotificationCenter.default.post(
            name: .limpidCommandPaletteExecute,
            object: action
        )
    }
}
