// SupervisionSecondaryButtonStyle.swift
// Limpid — the supervision window's small bordered button, on the window's surface color.

import SwiftUI

/// The supervision UI's bordered button: medium text on the window's
/// surface color, edged in `line`, its corners 6pt. Hovering fills it with
/// `hover` and pressing with `selection`; disabled, it fades to half, as
/// the primary style does. Its height is fixed like the primary's (22pt,
/// 20pt compact, 18pt mini), so what sits beside it can count on it. The destructive
/// style (`SupervisionDestructiveButtonStyle`) is this button in its
/// `.destructive` tone.
/// `.compact` is the size a row's own button takes (Answer… beside a Needs
/// Attention row) under a heading's (Next Action); `.mini` is a review hunk
/// header's, whose 10.5pt line it sits on.
struct SupervisionSecondaryButtonStyle: ButtonStyle {
    enum Size {
        case regular
        case compact
        case mini

        var height: CGFloat {
            switch self {
            case .regular: LimpidLayout.Supervision.secondaryButtonHeight
            case .compact: LimpidLayout.Supervision.secondaryButtonCompactHeight
            case .mini: LimpidLayout.Supervision.secondaryButtonMiniHeight
            }
        }

        var fontSize: LimpidFont.Supervision.Size {
            switch self {
            case .regular: .row
            case .compact: .meta
            case .mini: .caption
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: LimpidLayout.Supervision.spaceM
            case .compact: LimpidLayout.Supervision.spaceS
            case .mini: LimpidLayout.Supervision.spaceSnug
            }
        }
    }

    /// The title's color and edge: the text color, the stop color for a
    /// refusal or a destructive action (still edged and never filled in the
    /// accent, so it never reads as the primary button), or a ghost's muted,
    /// unedged face.
    enum Tone {
        case standard
        /// A button that refuses: the approval card's Deny.
        case refusal
        /// A button that rewrites the person's files. It looks like
        /// a refusal for now; the two are kept apart so one can change
        /// without the other.
        case destructive
        /// A quiet button beside the content it acts on (a hunk's Comment,
        /// the review band's Close): muted and unedged at rest, filled and
        /// in the text color while hovered, so it reads as pressable
        /// without a border competing with what it sits on.
        case ghost
        /// A button standing inside a state's soft fill (the notification
        /// history's notice): an opaque neutral face at every step, so it
        /// never takes on the fill's hue, and lighter than the fill, where
        /// the window's color would read as a hole cut in the band.
        case onStateFill
    }

    var size = Size.regular
    var tone = Tone.standard
    /// Whether the title is cut at its end where the row has no room for
    /// it whole, rather than held whole and pushing what follows out: the
    /// review band's "Choose Destination…" in a column narrower than its
    /// narrowest fit, so Close stays in the column.
    var truncatesTitle = false

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, size: size, tone: tone, truncatesTitle: truncatesTitle)
    }

    /// A view of its own, so it can hold the hover and read whether the
    /// button is enabled.
    private struct Face: View {
        let configuration: Configuration
        let size: Size
        let tone: Tone
        let truncatesTitle: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity
        @Environment(\.popoverSurface.ground) private var ground
        @Environment(\.popoverSurface.ink) private var ink
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.buttonCornerRadius, style: .continuous)
            configuration.label
                .font(.supervision(size.fontSize, weight: .medium))
                .foregroundStyle(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: !truncatesTitle, vertical: true)
                .padding(.horizontal, size.horizontalPadding)
                .frame(height: size.height)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(edge, lineWidth: 1))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : SupervisionTokens.disabledOpacity)
                .onHover { isHovering = $0 }
        }

        private var title: Color {
            switch tone {
            case .standard, .onStateFill: ink.text
            case .refusal, .destructive: SupervisionTokens.stoppedText.color
            case .ghost: isHovering && isEnabled ? ink.text : ink.muted
            }
        }

        private var edge: Color {
            switch tone {
            case .ghost: .clear
            case .onStateFill: SupervisionTokens.stateFillButtonEdge.color
            case .standard, .refusal, .destructive: ink.line
            }
        }

        /// As see-through as the surface the button is on, so with
        /// transparency on it does not stand out as an opaque box; on an
        /// opaque ground (the decision bar) the ground says 1. Pressed and
        /// hovered take their popover ground's fills (`PopoverGround`):
        /// on a panel's material the opaque ones all but vanish.
        private var fill: Color {
            if tone == .onStateFill {
                return stateFillFace.color
            }
            let token: RowFill? = if configuration.isPressed {
                ground.selection
            } else if isHovering, isEnabled {
                ground.hover
            } else {
                tone == .ghost ? nil : .solid(SupervisionTokens.window)
            }
            return token.map { $0.color.opacity(surfaceOpacity) } ?? .clear
        }

        private var stateFillFace: ThemedColor {
            if configuration.isPressed {
                SupervisionTokens.stateFillButtonPressed
            } else if isHovering, isEnabled {
                SupervisionTokens.stateFillButtonHover
            } else {
                SupervisionTokens.stateFillButton
            }
        }
    }
}

extension ButtonStyle where Self == SupervisionSecondaryButtonStyle {
    static var supervisionSecondary: SupervisionSecondaryButtonStyle {
        SupervisionSecondaryButtonStyle()
    }

    static func supervisionSecondary(size: SupervisionSecondaryButtonStyle.Size) -> SupervisionSecondaryButtonStyle {
        SupervisionSecondaryButtonStyle(size: size)
    }

    static func supervisionSecondary(tone: SupervisionSecondaryButtonStyle.Tone) -> SupervisionSecondaryButtonStyle {
        SupervisionSecondaryButtonStyle(tone: tone)
    }

    static func supervisionSecondary(
        size: SupervisionSecondaryButtonStyle.Size,
        tone: SupervisionSecondaryButtonStyle.Tone
    ) -> SupervisionSecondaryButtonStyle {
        SupervisionSecondaryButtonStyle(size: size, tone: tone)
    }
}
