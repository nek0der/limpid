// TurnCardMoves.swift
// Weir — the moves on a turn's card in the changes panel: the viewed line's and the restore, as glyphs.

import SwiftUI

/// A turn card's moves (`ChangesPanelText.moves`) as glyph buttons where
/// the card's time stands: the viewed line's move (a check in a circle,
/// crossed to take the mark back) and the restore. Glyphs rather than worded
/// buttons, so the moves cost the card no line of its own; each says its
/// whole name in its tooltip. The card shows them at rest on the list's
/// last card with moves, and on any other while the pointer or the keyboard
/// is on it or the review reads it; its context menu and its VoiceOver
/// actions offer the same moves at all times. A view of its own, apart from
/// the card, which reads the window and the app: built from plain values,
/// the moves can be measured against the card in a test.
struct TurnCardMoves: View {
    let moves: [TurnCardMove]
    let perform: @MainActor (TurnCardMove.Kind) -> Void
    /// Where the keyboard is among the card's controls, so the glyphs stay
    /// while it moves from the card onto them.
    var focus: FocusState<TurnCardFocus?>.Binding?

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        HStack(spacing: Layout.turnMoveSpacing) {
            ForEach(moves) { move in
                button(move)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func button(_ move: TurnCardMove) -> some View {
        let button = Button {
            perform(move.kind)
        } label: {
            Self.glyph(move.kind)
        }
        .buttonStyle(.supervisionIcon(horizontalPadding: Layout.turnMovePadding))
        .disabled(!move.isEnabled)
        .help(Text(verbatim: move.help))
        // Named for a reader that reaches the glyphs alone, as a measured
        // or previewed view does; the card hides them from VoiceOver, which
        // hears the same moves as the row's actions.
        .accessibilityLabel(Text(verbatim: move.title))
        .accessibilityHint(Text(verbatim: move.note ?? ""))
        if let focus {
            button.focused(focus, equals: TurnCardFocus(move.kind))
        } else {
            button
        }
    }

    /// The glyph for `kind`. The viewed line's takes the button style's
    /// colors, which light it under the pointer; the restore is red, as a
    /// move that puts files back.
    @ViewBuilder static func glyph(_ kind: TurnCardMove.Kind) -> some View {
        switch kind {
        case .line(.markViewedThrough): image("checkmark.circle")
        case .line(.markUnviewedFrom): image("checkmark.circle.badge.xmark")
        case .restore: image("arrow.uturn.backward").foregroundStyle(SupervisionTokens.stoppedText.color)
        }
    }

    private static func image(_ name: String) -> some View {
        Image(systemName: name)
            .font(.supervision(.caption, weight: .medium))
            .frame(height: Layout.turnMoveHeight)
    }
}

/// The room `TurnCardMoves` takes, as glyphs alone in the buttons' padding:
/// what the card's time slot holds while the moves show, inside the row's
/// own button, whose label must not hold buttons.
struct TurnCardMovesRoom: View {
    let moves: [TurnCardMove]

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        HStack(spacing: Layout.turnMoveSpacing) {
            ForEach(moves) { move in
                // As the moves' button style pads it.
                TurnCardMoves.glyph(move.kind)
                    .padding(.horizontal, Layout.turnMovePadding)
            }
        }
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
    }
}

/// Where the keyboard is on a turn card: on the card itself, or on one of
/// its two moves, by place rather than by move, so the focus stays when a
/// move of the line turns into its opposite.
enum TurnCardFocus: Hashable {
    case card
    case line
    case restore

    init(_ kind: TurnCardMove.Kind) {
        switch kind {
        case .line: self = .line
        case .restore: self = .restore
        }
    }
}

/// Why a restore is off, in a muted line under the card: a held-back glyph
/// says its reason only in its tooltip, which leaves the reader unsure
/// whether the move is broken or only waiting. Under the list's last card
/// that offers a restore only (`ChangesPanelModel.placeBlockerNote`), which
/// shows its moves at rest. Hidden from VoiceOver, which hears the reason as
/// the card's hint.
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
