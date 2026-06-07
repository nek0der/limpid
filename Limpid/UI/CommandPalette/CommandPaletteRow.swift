// CommandPaletteRow.swift
// Limpid — single result row in the command palette.

import SwiftUI

struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    let matchedIndices: [Int]
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                highlightedTitle
                    .font(LimpidFont.paletteItem)
                    .lineLimit(1)

                if let alias = item.searchAlias {
                    Text(alias)
                        .font(LimpidFont.caption)
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(LimpidFont.caption)
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let shortcut = item.shortcutDisplay {
                Text(shortcut)
                    .font(LimpidFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
        }
        .opacity(item.isEnabled ? 1.0 : 0.4)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6))
        .onTapGesture { if item.isEnabled { onTap() } }
        .onHover { isHovering = $0 }
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

    // MARK: - Background

    private var rowBackground: Color {
        if isSelected {
            return LimpidColor.rowActiveFill
        }
        if isHovering {
            return LimpidColor.rowHoverFill
        }
        return .clear
    }
}
