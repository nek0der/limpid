// ReviewFindBar.swift
// Limpid — finding text in the file the diff is showing.
//
// Its own file rather than more of `ReviewPane`, which had reached the length
// one file is allowed. Nothing here reads the diff: the surface counts the
// matches and decides which one is current, and this says so and takes the
// keys.

import SwiftUI

/// The strip under the file bar. There rather than in the header because it
/// belongs to the diff, and a reader who switches file keeps the query they
/// are hunting for.
struct ReviewFindBar: View {
    @Binding var search: ReviewSearch
    let hitCount: Int
    /// Which match is current, already held inside `hitCount`.
    let position: Int
    let onMove: (Int) -> Void
    let onClose: () -> Void
    /// Passed through to the field. See `ReviewFindField.focusRequest`.
    let focusRequest: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(LimpidColor.tertiaryText)
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
            Text(verbatim: summary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(LimpidColor.tertiaryText)
            Button {
                onMove(-1)
            } label: {
                Image(systemName: "chevron.up").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .disabled(hitCount == 0)
            .accessibilityLabel(Text("Previous Match"))
            Button {
                onMove(1)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .disabled(hitCount == 0)
            .accessibilityLabel(Text("Next Match"))
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .pointerStyle(.default)
            .accessibilityLabel(Text("Close Find Bar"))
        }
        .foregroundStyle(LimpidColor.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(LimpidColor.rowActiveFill.opacity(0.5).pointerStyle(.default))
    }

    /// Blank until there is something to count, so an empty field does not
    /// answer "0" to a question nobody asked.
    private var summary: String {
        guard search.isActive else { return "" }
        guard hitCount > 0 else { return String(localized: "No matches") }
        return "\(position + 1)/\(hitCount)"
    }
}
