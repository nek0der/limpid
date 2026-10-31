// TurnReplyLine.swift
// Weir — what the agent said as a turn ended, under what the turn did.

import SwiftUI

/// A turn's reply, led by a mark that says it is the agent's answer to the
/// prompt above it. The changes panel's card and the notification
/// history's row draw it here, so the two read as the same thing; each
/// keeps its own size and how many lines it gives the reply. The words are
/// muted, as the facts above them are, and the mark is held to 3:1 as
/// marks are.
struct TurnReplyLine: View {
    let reply: String
    let size: WeirFont.Supervision.Size
    let lineLimit: Int
    /// Struck out with the prompt, for a turn a restore took back.
    var isStruckOut = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceXS) {
            Image(systemName: "arrow.turn.down.right")
                .font(.supervision(.glyph))
                .foregroundStyle(SupervisionTokens.closedMark.color)
            Text(verbatim: reply)
                .font(.supervision(size))
                .foregroundStyle(SupervisionTokens.muted.color)
                .strikethrough(isStruckOut)
                .lineLimit(lineLimit)
                .supervisionTruncation(.sentence)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A card's line for what the agent tried and its own check refused. One line,
/// in the waiting tone with a symbol, so the color is not all that says it.
/// A long action is cut; how many others there are stays in full.
struct TurnDeniedLine: View {
    let action: String
    let more: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceXS) {
            Image(systemName: "nosign")
                .font(.supervision(.glyph))
            Text(verbatim: action)
                .font(.supervision(.caption))
                .lineLimit(1)
                .supervisionTruncation(.sentence)
            if let more {
                Text(verbatim: more)
                    .font(.supervision(.caption))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(SupervisionTokens.waitingText.color)
    }
}
