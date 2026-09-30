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

    var body: some View {
        HStack(spacing: spacing) {
            Text(verbatim: "+\(added)")
                .foregroundStyle(LimpidColor.success)
            Text(verbatim: "−\(removed)")
                .foregroundStyle(LimpidColor.error)
        }
    }
}
