// TurnCardMoves.swift
// Limpid — the moves under a turn's card in the changes panel, kept inside the card at the panel's narrowest.

import SwiftUI

/// A turn card's moves: the viewed line's move and the restore entry, both
/// compact edged buttons, so the two side by side have one form and
/// the move does not take the blue that marks unread and unviewed. Wrapped
/// rather than cut when the panel is too narrow for both, and where it is
/// too narrow for the whole restore entry on a line of its own (in English
/// at the panel's narrowest, 300pt), the entry takes its short form,
/// "Restore Code…": the button keeps its words at any width, so the whole
/// entry would draw past the card's edge. A view of its own, apart from
/// the card, which reads the window and the app: built from plain values,
/// the moves can be measured against the panel in a test.
struct TurnCardMoves: View {
    /// "Mark as Viewed up to Here" or "Mark as Unviewed from Here".
    struct LineMove {
        let title: String
        /// The title where the whole one does not fit the card ("Mark All
        /// as Viewed up to Here"); `nil` where the move has no shorter form.
        /// VoiceOver hears the whole title either way.
        var shortTitle: String?
        /// What the tooltip adds to the title, where the move reaches
        /// beyond this row's conversation; `nil` for the title alone.
        var help: String?
        let perform: @MainActor () -> Void
    }

    /// The card's "Restore Code to Before This Turn…".
    struct Restore {
        /// Why the restore cannot run now (`ChangesPanelModel.Row`).
        let blocker: RestoreGate.Blocker?
        /// Whether that reason is said under the moves
        /// (`ChangesPanelModel.placeBlockerNote`).
        var showsBlockerNote = false
        let ask: @MainActor () -> Void
    }

    let lineMove: LineMove?
    let restore: Restore?
    /// This is true when the turn is at or above its conversation's viewed line. An
    /// unviewed card carries the blue rule, and a viewed one had nothing
    /// but its "Mark as Unviewed from Here" to say so; the mark says it
    /// before the move that takes it back.
    var isViewed = false
    @Environment(\.locale) private var locale

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.turnActionLineSpacing) {
            FlowLayout(spacing: Layout.turnActionSpacing, lineSpacing: Layout.turnActionLineSpacing) {
                if isViewed {
                    Label(ChangesPanelText.status(.viewed, locale: locale), systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.supervision(.caption, weight: .medium))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .fixedSize()
                }
                if let lineMove {
                    ViewThatFits(in: .horizontal) {
                        lineMoveButton(lineMove.title, perform: lineMove.perform)
                        if let shortTitle = lineMove.shortTitle {
                            lineMoveButton(shortTitle, perform: lineMove.perform)
                        }
                    }
                    .help(Text(verbatim: lineMove.help ?? lineMove.title))
                    .accessibilityLabel(Text(verbatim: lineMove.title))
                    .accessibilityHint(Text(verbatim: lineMove.help ?? ""))
                }
                if let restore {
                    RestoreEntryButton(
                        title: RestoreText.entry(locale: locale),
                        shortTitle: RestoreText.shortEntry(locale: locale),
                        blocker: restore.blocker,
                        ask: restore.ask
                    )
                }
            }
            // Under the moves rather than inside the flow, so the reason
            // wraps to the card's width instead of widening the entry's slot.
            if let restore, restore.showsBlockerNote, let blocker = restore.blocker {
                RestoreBlockerNote(blocker: blocker)
            }
        }
    }

    private func lineMoveButton(_ title: String, perform: @escaping @MainActor () -> Void) -> some View {
        Button(title) {
            perform()
        }
        .buttonStyle(.supervisionSecondary(size: .compact))
    }
}

/// Why a restore entry is off, in a muted line under it: a held-back
/// button says its reason, since a tooltip alone leaves the reader unsure
/// whether the entry is broken or only waiting. Under the list's last entry
/// only (`ChangesPanelModel.placeBlockerNote`). Hidden from VoiceOver, which
/// already hears the reason as the entry's hint.
struct RestoreBlockerNote: View {
    let blocker: RestoreGate.Blocker
    @Environment(\.locale) private var locale

    var body: some View {
        Text(verbatim: RestoreText.blocker(blocker, locale: locale))
            .font(.supervision(.caption))
            .foregroundStyle(SupervisionTokens.muted.color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }
}

/// A restore entry of the panel: opens the strip in the bar of the
/// turn's pane, and says why it is off while the gate holds it back. With
/// a short form, it takes that one where the whole title does not fit the
/// width it is offered; the tooltip and VoiceOver still say the whole.
struct RestoreEntryButton: View {
    let title: String
    /// The title where the whole one does not fit; `nil` where the entry
    /// has no shorter form.
    var shortTitle: String?
    /// Why the restore cannot run now (`ChangesPanelModel.Row`).
    let blocker: RestoreGate.Blocker?
    let ask: @MainActor () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let reason = blocker.map { RestoreText.blocker($0, locale: locale) }
        ViewThatFits(in: .horizontal) {
            button(title)
            if let shortTitle {
                button(shortTitle)
            }
        }
        .disabled(reason != nil)
        .help(Text(verbatim: reason ?? title))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(verbatim: reason ?? ""))
    }

    private func button(_ title: String) -> some View {
        Button(title) {
            ask()
        }
        .buttonStyle(SupervisionDestructiveButtonStyle(size: .compact))
    }
}
