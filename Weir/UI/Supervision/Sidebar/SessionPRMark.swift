// SessionPRMark.swift
// Weir — a pull request's mark in line, as the supervision UI attaches it beside a session's badge.

import SwiftUI

/// A pull request's mark, attached on the right of a session beside its
/// agent badge: one line drawing per state, in `muted`, a draft the
/// open mark dashed, and its checks on its corner: a small red ✕ while a
/// check fails, an amber dot while one runs, and a thin green check once
/// they pass.
/// Lines rather than filled Octicons: a filled shape cannot be dashed, and
/// a 1.3pt line holds the weight of the glyphs and badges beside it.
struct SessionPRMark: View {
    let style: PRMarkPresentation
    /// The badge's height beside it, so the two share a box and a center
    /// line (`SessionAgentBadge.Size.height`).
    var size = WeirLayout.Supervision.agentBadgeHeight

    /// How much of the box the drawing takes. The badge beside it fills its
    /// box with color but sets its letters well inside it, so a drawing the
    /// box's full height reads a size larger than the badge; at this share
    /// its height matches the badge's letters and it still sits on the
    /// shared center line.
    static let drawingShare: CGFloat = 0.8

    var body: some View {
        let drawing = size * Self.drawingShare
        let scale = drawing / PRLineGlyph.viewBox
        PRLineGlyph(kind: style.kind)
            .stroke(
                style.tint,
                style: StrokeStyle(
                    // The line keeps the weight it has at the full box, so the
                    // smaller drawing holds the weight of the badge beside it.
                    lineWidth: 1.3 * size / PRLineGlyph.viewBox,
                    lineJoin: .round,
                    dash: style.kind == .draft ? [2.2 * scale, 1.6 * scale] : []
                )
            )
            .frame(width: drawing, height: drawing)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let badge = style.badge {
                    ChecksBadge(badge: badge)
                        .offset(
                            x: WeirLayout.Supervision.checksBadgeOffset,
                            y: WeirLayout.Supervision.checksBadgeOffset
                        )
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(style.accessibilityKey))
            // The checks are a colored corner mark and nothing else on screen.
            .accessibilityValue(style.badge.map { Text($0.accessibilityKey) } ?? Text(verbatim: ""))
    }
}

/// The corner mark for each outcome of a request's checks.
private struct ChecksBadge: View {
    let badge: PRMarkPresentation.Badge

    var body: some View {
        switch badge.kind {
        case .failing: ChecksFailedBadge(color: badge.color)
        case .running: ChecksRunningBadge(color: badge.color)
        case .passing: ChecksPassedBadge(color: badge.color)
        }
    }
}

/// The ✕ of a failing check: a red disc ringed in the window's color, so
/// it stands off the mark it hangs from, and a cross in the mark that the
/// stopped glyph puts on the same red.
private struct ChecksFailedBadge: View {
    let color: Color

    var body: some View {
        let size = WeirLayout.Supervision.checksBadgeSize
        Circle()
            .fill(color)
            .overlay {
                Path { path in
                    let inset = size * 0.32
                    path.move(to: CGPoint(x: inset, y: inset))
                    path.addLine(to: CGPoint(x: size - inset, y: size - inset))
                    path.move(to: CGPoint(x: size - inset, y: inset))
                    path.addLine(to: CGPoint(x: inset, y: size - inset))
                }
                .stroke(SupervisionTokens.onStopped.color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(SupervisionTokens.window.color)
                    .padding(-WeirLayout.Supervision.checksBadgeRingWidth)
            )
            .accessibilityHidden(true)
    }
}

/// A running check: the failing badge's disc in the waiting color, with no
/// glyph inside. A run is something to wait on, so it takes the waiting
/// color, and it has nothing to say until it settles.
private struct ChecksRunningBadge: View {
    let color: Color

    var body: some View {
        let size = WeirLayout.Supervision.checksBadgeSize
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(SupervisionTokens.window.color)
                    .padding(-WeirLayout.Supervision.checksBadgeRingWidth)
            )
            .accessibilityHidden(true)
    }
}

/// Passing checks: a thin green check with no disc, lighter than either
/// disc, so that the failing and running checks still stand out on a
/// sidebar where most requests pass.
private struct ChecksPassedBadge: View {
    let color: Color

    var body: some View {
        let size = WeirLayout.Supervision.checksPassedSize
        let lineWidth = WeirLayout.Supervision.checksPassedLineWidth
        ChecksPassedGlyph()
            .stroke(color, style: Self.style(lineWidth: lineWidth))
            .frame(width: size, height: size)
            // The long stroke crosses the commit the open and merged marks
            // put in that corner, and the two lines ran together there. The
            // same stroke in the window's color cuts the mark under it, as
            // the discs' ring does. It is half that ring on each side: on a
            // selected row, whose ground is not the window's, a full ring
            // drew a second check around the first.
            .background(
                ChecksPassedGlyph()
                    .stroke(
                        SupervisionTokens.window.color,
                        style: Self.style(lineWidth: lineWidth + WeirLayout.Supervision.checksBadgeRingWidth)
                    )
            )
            .accessibilityHidden(true)
    }

    private static func style(lineWidth: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    }
}

/// A check mark on a square: the short stroke down to the corner, then the
/// long one up to the far side.
private struct ChecksPassedGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.8))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.22))
        return path
    }
}

/// The pull request marks, on a 16-unit square, an icon's usual grid,
/// drawn as paths so they scale with the mark as the state glyphs do: the
/// open request
/// (two commits and the branch arrowing back), merged (the branch joined
/// in), and closed (the branch cut short under a cross).
struct PRLineGlyph: Shape {
    static let viewBox: CGFloat = 16

    let kind: PRMarkPresentation.Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let commit: CGFloat = 1.6
        func circle(_ x: CGFloat, _ y: CGFloat) {
            path.addEllipse(in: CGRect(x: x - commit, y: y - commit, width: 2 * commit, height: 2 * commit))
        }
        func line(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        circle(4.5, 3.5)
        circle(4.5, 12.5)
        line([CGPoint(x: 4.5, y: 5.1), CGPoint(x: 4.5, y: 10.9)])
        switch kind {
        case .open, .draft:
            circle(11.5, 12.5)
            path.move(to: CGPoint(x: 11.5, y: 10.9))
            path.addLine(to: CGPoint(x: 11.5, y: 6.5))
            path.addQuadCurve(to: CGPoint(x: 9.5, y: 4.5), control: CGPoint(x: 11.5, y: 4.5))
            path.addLine(to: CGPoint(x: 7.4, y: 4.5))
            line([CGPoint(x: 8.9, y: 3), CGPoint(x: 7.4, y: 4.5), CGPoint(x: 8.9, y: 6)])
        case .merged:
            circle(11.5, 8.5)
            path.move(to: CGPoint(x: 4.5, y: 5.4))
            path.addCurve(
                to: CGPoint(x: 9.9, y: 8.5),
                control1: CGPoint(x: 4.5, y: 8),
                control2: CGPoint(x: 6.9, y: 8.5)
            )
        case .closed:
            circle(11.5, 12.5)
            line([CGPoint(x: 11.5, y: 10.9), CGPoint(x: 11.5, y: 8.4)])
            line([CGPoint(x: 9.9, y: 3.4), CGPoint(x: 13.1, y: 6.6)])
            line([CGPoint(x: 13.1, y: 3.4), CGPoint(x: 9.9, y: 6.6)])
        }
        let scale = min(rect.width, rect.height) / Self.viewBox
        return path.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        )
    }
}
