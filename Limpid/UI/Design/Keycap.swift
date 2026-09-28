// Keycap.swift
// Limpid — a single keycap chip: one modifier symbol or one key glyph.
// Shared by the welcome list and the shortcut cheat sheet so a binding
// looks the same everywhere it is drawn as chips rather than as the
// inline `⌘⇧T` menu form.

import SwiftUI

struct Keycap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(LimpidColor.secondaryText)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, symbol.count > 1 ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(LimpidColor.rowActiveFill)
            )
    }
}

/// A row of keycaps for one binding. Reads as a single accessibility
/// element so VoiceOver announces "⌘⇧T", not three chips.
struct KeycapRow: View {
    let tokens: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Keycap(symbol: token)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tokens.joined()))
    }
}
