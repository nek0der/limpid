// DiffStatLabel.swift
// Limpid — the "+N −M" count of added and removed lines.
//
// The review header, the file header and the file list each wrote the
// pair out themselves. One view keeps the signs (a true minus, U+2212,
// not a hyphen) and the colors the same wherever a count appears; the
// site sets the font, since each draws the count at its own size.

import SwiftUI

struct DiffStatLabel: View {
    let added: Int
    let removed: Int
    /// The gap between the two counts. The file list sets its counts a
    /// size smaller than the headers and closes the gap to match.
    var spacing: CGFloat = 4
    @Environment(\.locale) private var locale

    var body: some View {
        // The diff tones and the figures grouped as the receipt
        // writes them ("+12,345"), so a count reads the same here as on the
        // decision bar and in the changes panel.
        HStack(spacing: spacing) {
            Text(verbatim: ReceiptText.signed(added, sign: "+", locale: locale))
                .foregroundStyle(SupervisionTokens.added.color)
            Text(verbatim: ReceiptText.signed(removed, sign: "−", locale: locale))
                .foregroundStyle(SupervisionTokens.removed.color)
        }
    }
}
