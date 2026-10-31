// ReviewFindBar.swift
// Weir — finding text in the review tab's stacked diff.
//
// Its own file rather than more of `ReviewPane`, which had reached the length
// one file is allowed. Nothing here reads the diff: the surface counts the
// matches and decides which one is current, and this says so and takes the
// keys.

import SwiftUI

/// The strip over the stacked diff. There rather than in the tab's top edge
/// because it belongs to the diff, and a reader who moves to another file
/// keeps the query they are hunting for.
struct ReviewFindBar: View {
    @Binding var search: ReviewSearch
    let hitCount: Int
    /// Which match is current, already held inside `hitCount`.
    let position: Int
    let onMove: (Int) -> Void
    let onClose: () -> Void
    /// Passed through to the field. See `ReviewFindField.focusRequest`.
    let focusRequest: Int
    /// What the bar says about where it searched, when that is not the
    /// whole of what it was asked to (the review tab's range).
    var note: String?

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceSnug) {
            Image(systemName: "magnifyingglass")
                .font(.supervision(.micro))
                .foregroundStyle(SupervisionTokens.muted.color)
            ReviewFindField(
                text: $search.query,
                onMove: onMove,
                onCancel: onClose,
                focusRequest: focusRequest
            )
            .accessibilityLabel(Text("Find in file"))
            .pointerStyle(.horizontalText)
            .onChange(of: search.query) { _, _ in
                // A new query starts at its first hit rather than wherever
                // the previous one had reached. Which hit that is comes from
                // the scan the surface debounces, not from here: moving on the
                // keystroke made every keystroke scan every row.
                search.index = 0
            }
            Text(display: summary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(SupervisionTokens.muted.color)
                .accessibilityLabel(Text(display: spokenSummary))
            if let note {
                Text(verbatim: note)
                    .font(.caption2)
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Text(verbatim: note))
            }
            Button {
                onMove(-1)
            } label: {
                Image(systemName: "chevron.up").font(.supervision(.micro))
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .disabled(hitCount == 0)
            // The field's own keys (`ReviewFindField`).
            .iconButtonHelp("Previous Match", shortcut: "⇧⏎")
            Button {
                onMove(1)
            } label: {
                Image(systemName: "chevron.down").font(.supervision(.micro))
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .disabled(hitCount == 0)
            .iconButtonHelp("Next Match", shortcut: "⏎")
            Button {
                onClose()
            } label: {
                DismissGlyph(size: .micro, weight: .regular)
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .iconButtonHelp("Close Find Bar", shortcut: "⎋")
        }
        .foregroundStyle(SupervisionTokens.muted.color)
        .padding(.horizontal, WeirLayout.Supervision.spaceS)
        .frame(height: 26)
        .background(WeirColor.rowActiveFill.opacity(0.5).pointerStyle(.default))
    }

    /// Blank until there is something to count, so an empty field does not
    /// answer "0" to a question nobody asked.
    private var summary: DisplayText {
        guard search.isActive else { return .verbatim("") }
        guard hitCount > 0 else { return .localized("No matches") }
        return .verbatim("\(position + 1)/\(hitCount)")
    }

    /// The summary as VoiceOver says it: a count, not "2 slash 5".
    private var spokenSummary: DisplayText {
        guard search.isActive, hitCount > 0 else { return summary }
        return .localized(LocalizedStringResource(
            "\(position + 1) of \(hitCount)",
            comment: "VoiceOver: the find bar’s current match, of how many"
        ))
    }
}
