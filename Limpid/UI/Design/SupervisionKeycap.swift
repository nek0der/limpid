// SupervisionKeycap.swift
// Limpid — a key combination in one cap, as the supervision window's palette shows it.

import SwiftUI

/// A whole key combination ("⇧⌘P") in one cap on the window's surface
/// color: a 1pt `line` edge, 2pt along the bottom so it reads as a key.
/// The palette's field and rows and the empty session area's commands
/// show their keys this way; the keyboard shortcut sheet keeps its
/// key-by-key caps.
struct SupervisionKeycap: View {
    enum Style: Equatable, Sendable {
        /// A key beside a control: medium weight on the `line` edge.
        case standard
        /// A key in a list that is itself a quiet hint (the empty session
        /// area): regular weight on a fainter edge, so the cap reads as the
        /// name's aside rather than louder than it.
        case quiet
    }

    let keys: String
    let size: LimpidFont.Supervision.Size
    let color: ThemedColor
    /// Whether the cap fills its face. A cap on a box filled in the window's
    /// color (the title bar's palette field at rest) draws only its edges:
    /// its face would be that same color, and laid on again at the ground's
    /// opacity it would stand out as a lighter box in the field.
    let isFaceFilled: Bool
    let style: Style
    /// Whether the type and the cap's height follow Dynamic Type: only
    /// beside words that do (the empty session area's names), so a key
    /// beside the palette's fixed type keeps its points.
    let scalesWithText: Bool

    @ScaledMetric private var scaledFontSize: CGFloat
    @ScaledMetric private var scaledHeight: CGFloat

    /// The quiet style's edge, as a share of the `line` color.
    private static let quietEdgeOpacity = 0.6

    init(
        keys: String,
        size: LimpidFont.Supervision.Size = .caption,
        color: ThemedColor = SupervisionTokens.text,
        isFaceFilled: Bool = true,
        style: Style = .standard,
        scalesWithText: Bool = false
    ) {
        self.keys = keys
        self.size = size
        self.color = color
        self.isFaceFilled = isFaceFilled
        self.style = style
        self.scalesWithText = scalesWithText
        _scaledFontSize = ScaledMetric(wrappedValue: size.rawValue, relativeTo: .callout)
        _scaledHeight = ScaledMetric(wrappedValue: LimpidLayout.Supervision.keycapHeight, relativeTo: .callout)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.keycapCornerRadius, style: .continuous)
        Text(verbatim: keys)
            .font(.system(size: fontSize, weight: style == .quiet ? .regular : .medium))
            .foregroundStyle(color.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, LimpidLayout.Supervision.keycapHorizontalPadding)
            .frame(height: height)
            // The face, as see-through as the ground the cap stands on.
            .background {
                if isFaceFilled {
                    SurfaceGround { shape.fill(SupervisionTokens.window.color) }
                }
            }
            .overlay(shape.strokeBorder(edgeColor, lineWidth: 1))
            // The deeper bottom edge: the cap stands 1pt higher on a fill of
            // the edge's color. Only the sliver below the face is drawn, so
            // with the face unfilled or see-through the edge's fill does not
            // show through it; whole, as the cap's other edges are.
            .padding(.bottom, 1)
            .background {
                ZStack(alignment: .top) {
                    shape.fill(edgeColor)
                    shape.fill(.black)
                        .padding(.bottom, 1)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: keys))
    }

    private var fontSize: CGFloat {
        scalesWithText ? scaledFontSize : size.rawValue
    }

    private var height: CGFloat {
        scalesWithText ? scaledHeight : LimpidLayout.Supervision.keycapHeight
    }

    private var edgeColor: Color {
        let line = SupervisionTokens.line.color
        return style == .quiet ? line.opacity(Self.quietEdgeOpacity) : line
    }
}
