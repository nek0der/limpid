// FlowLayout.swift
// Weir — lays its views out in lines, wrapping to the next when one is full.

import SwiftUI

/// Its views left to right at their own widths, moving to a new line when
/// the next would pass the width it is given, each line's views centered
/// on it. A view wider than a whole line is offered the line's width and
/// measured again there, so a text in it truncates (or wraps, taller)
/// rather than drawing past the edge. With no width proposed, everything
/// stays on one line: its ideal size.
///
/// Sizing and placing arrange the same views against the same width (the
/// proposed one), so the lines placed are the lines measured.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return Self.arrange(Self.sizes(of: subviews, within: width), width: width, spacing: spacing, lineSpacing: lineSpacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let width = proposal.width ?? bounds.width
        let frames = Self.arrange(Self.sizes(of: subviews, within: width), width: width, spacing: spacing, lineSpacing: lineSpacing).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// Each view's ideal size, or its size at `width` when it is wider than
    /// that.
    private static func sizes(of subviews: Subviews, within width: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            return ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
        }
    }

    /// Where each view of `sizes` goes within `width`, and the size of the
    /// whole: as wide as its widest line, so arranging again at that width
    /// gives the same lines.
    static func arrange(
        _ sizes: [CGSize],
        width: CGFloat,
        spacing: CGFloat,
        lineSpacing: CGFloat
    ) -> (frames: [CGRect], size: CGSize) {
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var lines: [(indices: [Int], width: CGFloat)] = []
        for (index, size) in sizes.enumerated() {
            let itemWidth = min(size.width, width)
            if let last = lines.indices.last, lines[last].width + spacing + itemWidth <= width {
                // The x is the line's width so far, summed the same way
                // the line's width is, so the widest line is the width.
                frames[index] = CGRect(x: lines[last].width + spacing, y: 0, width: itemWidth, height: size.height)
                lines[last].indices.append(index)
                lines[last].width += spacing + itemWidth
            } else {
                frames[index] = CGRect(x: 0, y: 0, width: itemWidth, height: size.height)
                lines.append(([index], itemWidth))
            }
        }
        var y: CGFloat = 0
        for (lineIndex, line) in lines.enumerated() {
            let height = line.indices.map { sizes[$0].height }.max() ?? 0
            for index in line.indices {
                frames[index].origin.y = y + (height - sizes[index].height) / 2
            }
            y += height + (lineIndex == lines.count - 1 ? 0 : lineSpacing)
        }
        return (frames, CGSize(width: lines.map(\.width).max() ?? 0, height: y))
    }
}
