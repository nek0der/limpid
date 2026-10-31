// CommandPaletteRow.swift
// Weir — single result row in the command palette.

import SwiftUI

struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    let matchedIndices: [Int]
    /// Runs the row; `true` when it was clicked with ⌘.
    let onTap: (_ holdsCommand: Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        content
            .opacity(item.isEnabled ? 1.0 : 0.4)
            .padding(WeirLayout.Supervision.paletteRowInsets)
            .contentShape(Rectangle())
            .dropdownRowBackground(
                isSelected: isSelected,
                isHovering: isHovering,
                cornerRadius: WeirLayout.Supervision.smallControlCornerRadius,
                cornerStyle: .circular
            )
            .onClick { holdsCommand in
                if item.isEnabled {
                    onTap(holdsCommand)
                }
            }
            // VoiceOver's press runs the row as a plain click, said here
            // rather than left to how SwiftUI exposes a pair of taps.
            .accessibilityAction {
                if item.isEnabled {
                    onTap(false)
                }
            }
            .onHover { isHovering = $0 }
    }

    /// The row: one line, the icon, the name in the text color, what
    /// goes with it (its English name, its detail) after it in the muted
    /// token and cut short first, and the keys in a cap at the end.
    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceS) {
            Image(systemName: item.icon)
                .font(.supervision(.label))
                .foregroundStyle(SupervisionTokens.muted.color)
                .frame(width: 20, alignment: .center)
            highlightedTitle
                .font(.supervision(.label))
                .foregroundStyle(SupervisionTokens.text.color)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail {
                Text(verbatim: detail)
                    .font(.supervision(.meta))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: WeirLayout.Supervision.spaceXS)
            if let shortcut = item.shortcutDisplay {
                SupervisionKeycap(keys: shortcut, size: .meta, color: SupervisionTokens.muted)
            }
        }
    }

    /// The English name and the detail, one after the other.
    private var detail: String? {
        let pieces = [item.searchAlias, item.subtitle].compactMap(\.self).filter { !$0.isEmpty }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    // MARK: - Highlighted title

    private var highlightedTitle: Text {
        var attributed = AttributedString(item.title)
        let matchSet = Set(matchedIndices)
        for i in matchSet {
            guard i < item.title.count else { continue }
            let start = attributed.index(attributed.startIndex, offsetByCharacters: i)
            let end = attributed.index(start, offsetByCharacters: 1)
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }
}
