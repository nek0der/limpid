// NeedsAttentionHeading.swift
// Limpid — the line over the Needs Attention rows, and the warning under it, in the list and the menu bar.

import SwiftUI

/// The count over the rows, quiet, with a control at its end when the
/// place it is in has one: Next Action in the title bar's list, ⋯ in the
/// menu bar. The line keeps a button's height without one, so the rows'
/// top does not move as the control comes and goes.
struct NeedsAttentionHeading<Trailing: View>: View {
    let title: LocalizedStringResource
    /// Where the title starts: in line with the rows' words, which stand
    /// further in in a popover than in the menu bar's window.
    let wordsInset: CGFloat
    @ViewBuilder let trailing: Trailing
    @Environment(\.popoverSurface.ink) private var ink

    init(
        _ title: LocalizedStringResource,
        wordsInset: CGFloat = LimpidLayout.Supervision.popoverWordsInset,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.wordsInset = wordsInset
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: LimpidLayout.Supervision.spaceSnug) {
            Text(title)
                .font(.supervision(.row))
                .foregroundStyle(ink.muted)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LimpidLayout.Supervision.spaceSnug)
            trailing
        }
        .frame(minHeight: LimpidLayout.Supervision.secondaryButtonHeight)
        .padding(.top, LimpidLayout.Supervision.needsAttentionHeadingTopInset)
        .padding(.leading, wordsInset)
        .padding(.trailing, LimpidLayout.Supervision.popoverControlInset)
        .padding(.bottom, LimpidLayout.Supervision.needsAttentionHeadingBottomInset)
    }
}

/// The approval service is close to its limit: new requests will not be
/// held, so they will be answered in the terminal instead.
struct NeedsAttentionCapacityWarning: View {
    let isNearCapacity: Bool
    /// In line with the rows' words, as the heading's are.
    var wordsInset: CGFloat = LimpidLayout.Supervision.popoverWordsInset
    @Environment(\.popoverSurface.ink) private var ink

    var body: some View {
        if isNearCapacity {
            Label {
                Text("Too many approvals are held. New approvals will show in the terminal.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SupervisionTokens.waiting.color)
            }
            .font(.supervision(.row))
            .foregroundStyle(ink.warningText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, wordsInset)
            .padding(.vertical, LimpidLayout.Supervision.spaceS)
        }
    }
}
