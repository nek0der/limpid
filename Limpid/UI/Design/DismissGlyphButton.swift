// DismissGlyphButton.swift
// Limpid — the "×" that closes or dismisses the thing it sits on.
//
// Rows, toasts, panel headers and sheets draw their × through this
// component, so the glyph size and weight, the hit area, the
// accessibility label and the tooltip agree across them; a site picks
// only what it closes and how prominent the control is. The approval
// card's header, the two find bars, and the changes panel's header keep
// buttons of their own, since each takes keyboard focus, a button style, a
// hit area, or a tooltip with its key that this one does not; they draw
// their × through `DismissGlyph`, as this does.

import SwiftUI

/// This is the × every dismiss control draws, at the size and weight its
/// place gives it. It is only the glyph: the button around it, its hit area,
/// color, focus, and tooltip are the control's.
struct DismissGlyph: View {
    var size: LimpidFont.Supervision.Size = .micro
    var weight: Font.Weight = .bold

    var body: some View {
        Image(systemName: "xmark")
            .font(.supervision(size, weight: weight))
    }
}

struct DismissGlyphButton: View {
    /// How much room the control gets. Two sizes rather than one: a row
    /// or a bar already gives the glyph a surface to sit on, while a
    /// sheet header or a floating capsule has only this control on its
    /// side and needs it to read as a button rather than as decoration.
    enum Size {
        /// Rows, bars, toasts and list headers.
        case regular
        /// Sheet headers and floating panels. Draws its own round ground.
        case large

        fileprivate var glyphSize: LimpidFont.Supervision.Size {
            switch self {
            case .regular: .micro
            case .large: .row
            }
        }

        /// The square the control hit-tests on. The regular size is
        /// 18 rather than the rows' 16pt status slot because the two
        /// places that already had a real hit area, the toast and the
        /// notification rows, sized their layout around 18. The rows
        /// only show the × on hover or selection, where 2pt more is lost
        /// in the label's own reflow.
        fileprivate var hitSize: CGFloat {
            switch self {
            case .regular: 18
            case .large: 24
            }
        }
    }

    /// The large size's round ground, as a corner radius, for a focus
    /// ring drawn around it.
    static let largeCornerRadius: CGFloat = Size.large.hitSize / 2

    /// What the button closes: the VoiceOver label, and the tooltip unless
    /// `help` says more. Required, so a site cannot leave the button
    /// unnamed: "×, button" says nothing about what goes away.
    let label: LocalizedStringResource
    var size: Size = .regular
    /// A tooltip that says more than the label, such as the key that
    /// also closes; the label when `nil`.
    var help: LocalizedStringResource?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DismissGlyph(size: size.glyphSize)
                .foregroundStyle(.secondary)
                .frame(width: size.hitSize, height: size.hitSize)
                .background {
                    if size == .large {
                        Circle().fill(Color.primary.opacity(0.06))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Several hosts sit over a terminal or a diff, whose I-beam would
        // otherwise carry onto the button.
        .pointerStyle(.default)
        .help(Text(help ?? label))
        .accessibilityLabel(Text(label))
    }
}
