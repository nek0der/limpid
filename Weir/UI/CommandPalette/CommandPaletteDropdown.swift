// CommandPaletteDropdown.swift
// Weir — material-backed results list for the command palette.
// Positioned by WindowChromeHost from the field's frame in
// `ProjectWindowState.paletteFieldFrame`; this view only renders the
// scrollable result list.

import SwiftUI

struct CommandPaletteDropdown: View {
    @Bindable var state: CommandPaletteState
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WindowRegistry.self) private var windowRegistry

    var body: some View {
        // Outer vertical padding shortens the inner `ScrollView`, which
        // shortens its legacy scroller track in turn — that's what
        // keeps the track from running flush into the palette's rounded
        // top + bottom corners. Clip BEFORE the surface treatment so the
        // scroller (track + thumb) is bounded by the rounded shape too.
        VStack(spacing: 0) {
            resultsList
            // Inside the surface's padding, rule and all, as the rows are.
            PrefixFoot()
                .padding(.horizontal, WeirLayout.Supervision.paletteDropdownPadding)
        }
        .padding(.vertical, WeirLayout.Supervision.paletteDropdownPadding)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .floatingPanelSurface(cornerRadius: 16)
        .pointerStyle(.default)
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
                            sectionHeader(section.category, isFirst: section.category == grouped.first?.category)
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
                                    onTap: { execute(scored.item.action, opensInNewWindow: $0) }
                                )
                                .id(scored.id)
                            }
                        }
                    }
                }
                // The rows keep to the surface's own inset: the outer
                // padding is its top and bottom.
                .padding(.horizontal, WeirLayout.Supervision.paletteDropdownPadding)
            }
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard newIndex >= 0, newIndex < state.results.count else { return }
                withAnimation(reduceMotion ? nil : WeirMotion.selectionScroll) {
                    proxy.scrollTo(state.results[newIndex].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        SupervisionEmptyState(.noResults, size: .compact)
    }

    /// Muted and in its own case: uppercase only shouts in English and does
    /// nothing in Japanese.
    private func sectionHeader(_ category: CommandPaletteCategory, isFirst: Bool) -> some View {
        Text(category.localizedTitle)
            .font(.supervision(.caption, weight: .semibold))
            .foregroundStyle(SupervisionTokens.muted.color)
            .padding(WeirLayout.Supervision.paletteHeadingInsets(isFirst: isFirst))
            .accessibilityAddTraits(.isHeader)
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
            if section.category == category {
                return index + offset
            }
            index += section.items.count
        }
        return index + offset
    }

    /// A click with ⌘ held opens another project's row in a new window,
    /// as ⌘Return does from the field.
    private func execute(_ action: CommandPaletteAction, opensInNewWindow: Bool) {
        CommandPaletteActions.postExecution(of: action, from: state, opensInNewWindow: opensInNewWindow, commands: windowRegistry)
    }
}

/// The prefixes the palette takes, along its foot below the rows:
/// each character in the monospaced face and the text color, then what it
/// narrows to, so the modes are found without typing "?".
private struct PrefixFoot: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SupervisionTokens.line.color)
                .frame(height: 1)
            HStack(spacing: WeirLayout.Supervision.paletteFootSpacing) {
                ForEach(PalettePrefix.allCases, id: \.self) { prefix in
                    HStack(spacing: WeirLayout.Supervision.spaceXS) {
                        Text(verbatim: String(prefix.character))
                            .font(.supervision(.meta, design: .monospaced))
                            .foregroundStyle(SupervisionTokens.text.color)
                        Text(prefix.shortName)
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .font(.supervision(.meta))
            .foregroundStyle(SupervisionTokens.muted.color)
            .padding(WeirLayout.Supervision.paletteFootInsets)
        }
        .accessibilityElement(children: .combine)
    }
}
