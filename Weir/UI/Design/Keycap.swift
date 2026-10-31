// Keycap.swift
// Weir — a single keycap chip: one modifier symbol or one key glyph.
// The keyboard shortcut panel draws a binding with it as chips, one per
// key, rather than in the inline `⌘⇧T` menu form.

import SwiftUI

struct Keycap: View {
    let symbol: String

    /// The chip is drawn in the window's tokens: `selection` for the chip
    /// and the muted token, which reads on it at 4.5:1.
    var body: some View {
        Text(symbol)
            .font(.supervision(.caption, weight: .medium, design: .rounded))
            .foregroundStyle(SupervisionTokens.muted.color)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, symbol.count > 1 ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(SupervisionTokens.selection.color)
            )
    }
}

/// A row of keycaps for one binding. Reads as a single accessibility
/// element so VoiceOver announces "⌘⇧T", not three chips.
struct KeycapRow: View {
    let tokens: [String]

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceXS) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Keycap(symbol: token)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tokens.joined()))
    }
}
