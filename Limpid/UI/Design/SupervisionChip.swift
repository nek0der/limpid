// SupervisionChip.swift
// Limpid — a short fact in a bordered chip on the window's color.

import AppKit
import SwiftUI

/// A word or a count in a small bordered box on the window's color (a
/// project's "Needs Attention 2", a card's "Commits 3"). At a background
/// opacity of 100% it carries its own ground, so its text reads at the same
/// contrast on a hovered or selected row as on the window. Under 100% that
/// ground is as see-through as the one it stands on (`SurfaceGround`), so
/// the chip is not an opaque box on the glass. The figures keep one width,
/// so a count that changes does not shift what follows it. The session
/// header's chips are the same box, measured with `width(of:hasIcon:)` to
/// decide which fit.
struct SupervisionChip: View {
    enum Tone {
        /// A plain fact: muted text in a `line` edge.
        case plain
        /// Something blocked on the person.
        case waiting
        /// Only unread turns.
        case unread
        /// Agents at work.
        case running
        /// Something gone past saving (an expired prompt cache).
        case stopped

        var text: Color {
            switch self {
            case .plain: SupervisionTokens.muted.color
            case .waiting: SupervisionTokens.waitingText.color
            case .unread: SupervisionTokens.unreadText.color
            case .running: SupervisionTokens.running.color
            case .stopped: SupervisionTokens.stoppedText.color
            }
        }

        var edge: Color {
            switch self {
            case .plain: SupervisionTokens.line.color
            case .waiting: SupervisionTokens.waiting.color
            case .unread: SupervisionTokens.unread.color
            case .running: SupervisionTokens.running.color
            case .stopped: SupervisionTokens.stopped.color
            }
        }
    }

    let text: Text
    var tone = Tone.plain
    /// A symbol before the words, for a chip whose words alone would not
    /// say what it is about (the folded sidebar, the prompt cache's clock).
    var systemImage: String?

    /// The face the words are drawn in, which `width(of:hasIcon:)` measures.
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: LimpidFont.Supervision.Size.caption.rawValue, weight: .regular)
    private static let iconStep = LimpidFont.Supervision.Size.micro
    private static let iconSize = iconStep.rawValue
    private static let iconSpacing: CGFloat = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.chipCornerRadius, style: .continuous)
        HStack(spacing: Self.iconSpacing) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.supervision(Self.iconStep, weight: .semibold))
                    .frame(width: Self.iconSize)
                    .accessibilityHidden(true)
            }
            text
                .font(Font(Self.font))
                .lineLimit(1)
                // Cut only when the chip is offered less than its words (a
                // card narrower than one chip), never drawn past its place.
                .truncationMode(.tail)
        }
        .foregroundStyle(tone.text)
        .padding(.horizontal, LimpidLayout.Supervision.chipHorizontalPadding)
        .frame(height: LimpidLayout.Supervision.chipHeight)
        .background(SurfaceGround { shape.fill(SupervisionTokens.window.color) })
        .overlay(shape.strokeBorder(tone.edge, lineWidth: 1))
        // Beside a name that can be cut, the name gives way first.
        .layoutPriority(1)
    }

    /// The width a chip with `text` takes, for deciding which chips fit
    /// beside a name that must not be cut (the session header).
    static func width(of text: String, hasIcon: Bool) -> CGFloat {
        let words = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let icon = hasIcon ? iconSize + iconSpacing : 0
        return words + icon + 2 * LimpidLayout.Supervision.chipHorizontalPadding
    }
}
