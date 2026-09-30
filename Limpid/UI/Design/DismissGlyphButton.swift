// DismissGlyphButton.swift
// Limpid — the "×" that closes or dismisses the thing it sits on.
//
// Every row, toast, panel header and sheet used to draw its own ×, and
// no two agreed: glyph sizes ran from 9 to 12pt in three weights, the
// hit area was 16, 18, 24 or just the glyph, and a few had an
// accessibility label but no tooltip. One component owns all of it, so
// a site picks only what it closes and how prominent the control is.

import SwiftUI

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

        fileprivate var glyphSize: CGFloat {
            switch self {
            case .regular: 10
            case .large: 12
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

    /// What the button closes, as both the tooltip and the VoiceOver
    /// label. One value for both so a site cannot label one and forget
    /// the other: "×, button" says nothing about what goes away.
    let label: LocalizedStringResource
    var size: Size = .regular
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size.glyphSize, weight: .bold))
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
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}
