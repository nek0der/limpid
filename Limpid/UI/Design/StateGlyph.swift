// StateGlyph.swift
// Limpid — the one state icon the sidebar, lists, cards, history, and menu bar share.

import SwiftUI

/// A session's or item's state, drawn the same everywhere. Shape,
/// color, and a mark carry it together, so it never rests on color alone.
/// Only what needs the person is filled: an amber disc with a white "?" waits
/// for an answer, a red disc with a white "!" has stopped. The rest are
/// lines: a ring with a dot in the accent is unread, a gray quarter arc on
/// a pale track runs, a faint ring is idle (`StateGlyphGeometry.idleInk`),
/// and a dashed ring is unknown: an agent not matched to its hook yet,
/// whose row would otherwise show an empty slot beside a line that names
/// a state. Where a place shows no mark for unknown (a pane's
/// header, its tab), that place leaves it out; the glyph always draws.
/// Work an agent left running when its turn ended is the idle ring, or the
/// unread ring and its dot, with a small dot going round on the ring
/// (`StateGlyphOrbit`): the turn is over, so the rest's shape stays, and
/// the moving dot says something still runs. It is a dot rather than an
/// arc, so it never reads as a turn in progress; under Reduce Motion it
/// stays still on the ring, where the shape alone still tells it apart
/// from the rest.
struct StateGlyph: View {
    enum Kind: Equatable {
        case needsApproval
        case needsAnswer
        /// A wait at the agent's prompt we cannot name as an approval or a
        /// question.
        case needsResponse
        /// The agent waits for the person to sign in again.
        case needsSignIn
        case stopped
        case unread
        /// An unread turn whose run still has work running after it.
        case unreadWorkingAfterTurn
        case running
        case idle
        /// A rest whose agent still has work running after its turn.
        case workingAfterTurn
        case unknown

        /// The state's name, which VoiceOver reads.
        var name: LocalizedStringResource {
            switch self {
            case .needsApproval: LocalizedStringResource("Needs approval", comment: "State: an approval request waits")
            case .needsAnswer: LocalizedStringResource("Needs answer", comment: "State: a question waits")
            case .needsResponse: LocalizedStringResource(
                    "Needs response",
                    comment: "State: a wait at the agent's prompt that cannot be named as an approval or a question"
                )
            case .needsSignIn: LocalizedStringResource(
                    "Needs sign-in",
                    comment: "State: the agent cannot go on until the person signs in again"
                )
            case .stopped: LocalizedStringResource("Stopped", comment: "State: the agent stopped (an error, an exit, a limit)")
            case .unread: LocalizedStringResource("Unread", comment: "State: a finished turn not read yet")
            case .unreadWorkingAfterTurn: LocalizedStringResource(
                    "Unread, working in the background",
                    comment: "State: a finished turn not read yet, whose agent still works in the background after it"
                )
            case .running: LocalizedStringResource("Running", comment: "State: a turn is in progress")
            case .idle: LocalizedStringResource("Idle", comment: "State: nothing in progress or waiting")
            case .workingAfterTurn: LocalizedStringResource(
                    "Working in the background",
                    comment: "State: the agent's turn is over, and it still works in the background"
                )
            case .unknown: LocalizedStringResource("Unknown", comment: "State: not known yet")
            }
        }
    }

    let kind: Kind
    var size: CGFloat = LimpidLayout.Supervision.stateGlyphSize
    /// What the unread ring and dot are drawn in on a row filled with the
    /// system's accent (the menu bar's lit row), where a ring in the
    /// accent would vanish into the fill; `nil` everywhere else, where
    /// they take the person's accent.
    var inkOnAccentFill: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.limpidAccent) private var accent

    var body: some View {
        face(isReduceMotionOn: reduceMotion, contrast: contrast, accent: accent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(kind.name))
    }

    /// The face for what the environment says, apart from `body` so a test
    /// can give it each contrast and motion setting: SwiftUI lets a view
    /// read those, not set them.
    func face(isReduceMotionOn: Bool, contrast: ColorSchemeContrast, accent: Color) -> StateGlyphFace {
        StateGlyphFace(
            kind: kind,
            size: size,
            isTurning: !isReduceMotionOn,
            isContrastIncreased: contrast == .increased,
            unreadInk: inkOnAccentFill ?? SupervisionTokens.accentIcon(color: accent)
        )
    }
}

/// The glyph as it is drawn, with what `StateGlyph` reads from the
/// environment passed in, so a test can draw each state in each
/// appearance and contrast without a window to set them on.
struct StateGlyphFace: View {
    let kind: StateGlyph.Kind
    let size: CGFloat
    let isTurning: Bool
    let isContrastIncreased: Bool
    let unreadInk: Color

    private var geometry: StateGlyphGeometry {
        StateGlyphGeometry(size: size, isContrastIncreased: isContrastIncreased)
    }

    var body: some View {
        glyph
            .frame(width: size, height: size)
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .needsApproval, .needsAnswer, .needsResponse, .needsSignIn:
            disc(SupervisionTokens.waitingGlyph, edge: SupervisionTokens.waitingGlyphEdge) {
                StateGlyphQuestionMark(geometry: geometry)
                    .stroke(
                        SupervisionTokens.onWaiting.color,
                        style: StrokeStyle(lineWidth: geometry.questionStrokeWidth, lineCap: .round, lineJoin: .round)
                    )
                StateGlyphMarkDot(geometry: geometry, center: StateGlyphGeometry.questionDotCenter)
                    .fill(SupervisionTokens.onWaiting.color)
            }
        case .stopped:
            disc(SupervisionTokens.stopped, edge: nil) {
                StateGlyphExclamationBar(geometry: geometry)
                    .fill(SupervisionTokens.onStopped.color)
                StateGlyphMarkDot(geometry: geometry, center: StateGlyphGeometry.exclamationDotCenter)
                    .fill(SupervisionTokens.onStopped.color)
            }
        case .unread:
            unreadRing
        case .unreadWorkingAfterTurn:
            ZStack {
                unreadRing
                StateGlyphOrbit(geometry: geometry, ring: .unread, isTurning: isTurning)
            }
        case .running:
            RunningArc(size: size, isTurning: isTurning)
        case .idle:
            idleRing
        case .workingAfterTurn:
            ZStack {
                idleRing
                StateGlyphOrbit(geometry: geometry, ring: .idle, isTurning: isTurning)
            }
        case .unknown:
            Circle()
                .inset(by: geometry.ringWidth(.unknown) / 2)
                .stroke(
                    geometry.unknownInk.color,
                    style: StrokeStyle(lineWidth: geometry.ringWidth(.unknown), lineCap: .round, dash: geometry.unknownDash)
                )
        }
    }

    private var unreadRing: some View {
        ZStack {
            Circle()
                .strokeBorder(unreadInk, lineWidth: geometry.ringWidth(.unread))
            Circle()
                .fill(unreadInk)
                .frame(width: geometry.unreadDotDiameter, height: geometry.unreadDotDiameter)
        }
    }

    private var idleRing: some View {
        Circle()
            .strokeBorder(geometry.idleInk.color, lineWidth: geometry.ringWidth(.idle))
    }

    /// A disc with its mark. `edge` rings it inside, for a fill that
    /// stands under 3:1 off a light surface (`waitingGlyphEdge`).
    private func disc(_ fill: ThemedColor, edge: ThemedColor?, @ViewBuilder mark: () -> some View) -> some View {
        Circle()
            .fill(fill.color)
            .overlay {
                if let edge {
                    Circle().strokeBorder(edge.color, lineWidth: LimpidLayout.Supervision.agentBadgeEdgeWidth)
                }
            }
            .overlay {
                ZStack(content: mark)
            }
    }
}

/// Where the glyph's parts fall, on a 16-unit square, an icon's usual
/// grid. The disc is 14 units across, a unit in from each side, and the
/// glyph's frame is that disc, so a unit is a fourteenth of it. The marks
/// are drawn as paths rather than set in a font, so "!" and "?" keep the
/// same proportions at every size, down to the 11pt of a tab's mark and a
/// folded heading (`stateGlyphCompactSize`), rather than
/// following a font's own weights and hinting there.
struct StateGlyphGeometry: Equatable {
    enum Ring {
        case unread
        case idle
        case unknown
    }

    let size: CGFloat
    let isContrastIncreased: Bool

    /// The disc's diameter in the square's units.
    static let discUnits: CGFloat = 14
    static let exclamationBar = CGRect(x: 7.1, y: 3.6, width: 1.8, height: 5.6)
    static let exclamationDotCenter = CGPoint(x: 8, y: 11.6)
    static let questionDotCenter = CGPoint(x: 8, y: 12)
    static let markDotRadius: CGFloat = 1.05
    static let questionStrokeUnits: CGFloat = 1.7
    /// The "?" hook: an arc of radius 2.15 from (5.9, 6.1) over the top to
    /// (9, 8), given by its ends as an SVG path gives one, worked out once
    /// into its center and angles (y down, so a positive sweep turns
    /// clockwise on screen), then a curve down into a short stem.
    static let questionStart = CGPoint(x: 5.9, y: 6.1)
    static let questionArcCenter = CGPoint(x: 8.0498, y: 6.0714)
    static let questionArcRadius: CGFloat = 2.15
    static let questionArcStart = Angle.degrees(179.237)
    static let questionArcSweep = Angle.degrees(244.535)
    static let questionCurveControls = (CGPoint(x: 8.4, y: 8.32), CGPoint(x: 8, y: 8.7))
    static let questionStemTop = CGPoint(x: 8, y: 9.4)
    static let questionStemBottom = CGPoint(x: 8, y: 9.7)
    /// The unread ring's width in the square's units, and its dot's
    /// diameter: a ring heavier than the idle hairline, with a dot in its
    /// middle, so an unread row stands out from the resting ones.
    static let unreadRingUnits: CGFloat = 1.6
    static let unreadDotUnits: CGFloat = 6
    /// The idle ring is a hairline, so a list of resting rows stays quiet
    /// beside the one that is unread.
    static let idleRingWidth: CGFloat = 1
    /// What Increase Contrast adds to each ring: the idle ring reaches the
    /// 1.5pt we ask for, and the unread ring keeps its lead on it.
    static let increasedContrastRingGain: CGFloat = 0.5
    /// The going-round dot's diameter for the ring it goes round on, in
    /// that ring's widths: wide enough to stand out of the line it rides
    /// on as a dot of its own.
    static let orbitDotRingWidths: CGFloat = 1.8
    /// The least the going-round dot is across, in points. On the idle
    /// hairline the widths alone give under 2pt, which the 11pt of a tab's
    /// mark loses into the ring.
    static let orbitDotMinimumDiameter: CGFloat = 2.4

    /// One of the square's units, in points.
    var unit: CGFloat {
        size / Self.discUnits
    }

    func ringWidth(_ ring: Ring) -> CGFloat {
        let base = switch ring {
        case .unread: Self.unreadRingUnits * unit
        case .idle, .unknown: Self.idleRingWidth
        }
        return base + (isContrastIncreased ? Self.increasedContrastRingGain : 0)
    }

    /// The idle ring's color. `faint` at rest, under the 3:1 a mark is
    /// otherwise held to, on purpose: idle is the resting state of most
    /// rows, says nothing to act on, and its name is still read out and
    /// shown in the tooltip; a ring at full contrast on every resting row
    /// would make the list loud beside the one row that asks for something.
    /// Under Increase Contrast, where the person asked for every mark to
    /// stand out, it takes `muted`, which reaches 4.5:1 on every surface.
    var idleInk: ThemedColor {
        isContrastIncreased ? SupervisionTokens.muted : SupervisionTokens.faint
    }

    /// How many dashes the unknown ring is cut into: few enough that each
    /// reads as a dash at the 11pt compact size, so the ring never passes
    /// for the idle one's solid line.
    static let unknownDashCount = 8

    /// The unknown ring's color: `muted`, a step louder than idle's
    /// `faint`. Unknown is passing (it lasts until the agent's first
    /// report), and its dashes are thin; at `faint` an empty-looking slot
    /// would come back, which is what the mark is there to end.
    var unknownInk: ThemedColor {
        SupervisionTokens.muted
    }

    /// The dash and the gap of the unknown ring, equal, so the ring's
    /// length splits into `unknownDashCount` of each. The round caps add
    /// half the line's width at each end, which the dash gives back.
    var unknownDash: [CGFloat] {
        let width = ringWidth(.unknown)
        let length = CGFloat.pi * (size - width)
        let step = length / CGFloat(Self.unknownDashCount * 2)
        return [max(step - width, 0.5), step + width]
    }

    var unreadDotDiameter: CGFloat {
        Self.unreadDotUnits * unit
    }

    /// The going-round dot's diameter on `ring`. It follows the ring's
    /// width, so Increase Contrast enlarges it with the ring.
    func orbitDotDiameter(on ring: Ring) -> CGFloat {
        max(Self.orbitDotRingWidths * ringWidth(ring), Self.orbitDotMinimumDiameter)
    }

    /// How far the going-round dot's center is from the glyph's: on the
    /// middle of `ring`'s line, so the dot stands out of the ring by the
    /// same on each side.
    func orbitRadius(on ring: Ring) -> CGFloat {
        (size - ringWidth(ring)) / 2
    }

    /// The going-round dot's color: the body text's ink, in every contrast.
    /// The running arc's gray barely stands apart from the faint idle ring
    /// in dark, too little for a dot a few points across at a tab's 11pt,
    /// and is one value with the `muted` ring Increase Contrast draws.
    var orbitInk: ThemedColor {
        SupervisionTokens.text
    }

    var questionStrokeWidth: CGFloat {
        Self.questionStrokeUnits * unit
    }

    /// A point of the 16-unit square, in the frame: the square stands one
    /// unit out from the disc on each side.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - 1) * unit, y: (y - 1) * unit)
    }

    func length(_ units: CGFloat) -> CGFloat {
        units * unit
    }
}

/// The bar of the stopped glyph's "!".
private struct StateGlyphExclamationBar: Shape {
    let geometry: StateGlyphGeometry

    func path(in _: CGRect) -> Path {
        let bar = StateGlyphGeometry.exclamationBar
        let origin = geometry.point(bar.minX, bar.minY)
        let rect = CGRect(origin: origin, size: CGSize(width: geometry.length(bar.width), height: geometry.length(bar.height)))
        return Path(roundedRect: rect, cornerRadius: rect.width / 2)
    }
}

/// The dot under a glyph's "!" or "?".
private struct StateGlyphMarkDot: Shape {
    let geometry: StateGlyphGeometry
    let center: CGPoint

    func path(in _: CGRect) -> Path {
        let radius = geometry.length(StateGlyphGeometry.markDotRadius)
        let middle = geometry.point(center.x, center.y)
        return Path(ellipseIn: CGRect(x: middle.x - radius, y: middle.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// The hook of the waiting glyph's "?" (`StateGlyphGeometry.question…`).
private struct StateGlyphQuestionMark: Shape {
    let geometry: StateGlyphGeometry

    func path(in _: CGRect) -> Path {
        typealias Grid = StateGlyphGeometry
        func point(_ unitPoint: CGPoint) -> CGPoint {
            geometry.point(unitPoint.x, unitPoint.y)
        }
        var path = Path()
        path.move(to: point(Grid.questionStart))
        path.addRelativeArc(
            center: point(Grid.questionArcCenter),
            radius: geometry.length(Grid.questionArcRadius),
            startAngle: Grid.questionArcStart,
            delta: Grid.questionArcSweep
        )
        path.addCurve(
            to: point(Grid.questionStemTop),
            control1: point(Grid.questionCurveControls.0),
            control2: point(Grid.questionCurveControls.1)
        )
        path.addLine(to: point(Grid.questionStemBottom))
        return path
    }
}

/// The running glyph: a gray quarter arc on a pale neutral track. Under
/// Reduce Motion the arc stays where it is, so the shape still differs
/// from the unread ring; only the turning stops. The turn is one repeating
/// animation the render server runs, rather than a body drawn again every
/// frame: a window with many running agents redrew every glyph sixty times
/// a second. Turning Reduce Motion off again starts it at once.
struct RunningArc: View {
    let size: CGFloat
    let isTurning: Bool
    @State private var isAtFullTurn = false

    /// The turn while the arc turns; none under Reduce Motion, so the arc
    /// is drawn still.
    static func turn(isTurning: Bool) -> Animation? {
        isTurning ? .linear(duration: 1).repeatForever(autoreverses: false) : nil
    }

    var body: some View {
        arc(angle: .degrees(isTurning && isAtFullTurn ? 360 : 0))
            .animation(Self.turn(isTurning: isTurning), value: isAtFullTurn)
            .onAppear { isAtFullTurn = isTurning }
            .onChange(of: isTurning) { _, isTurning in
                isAtFullTurn = isTurning
            }
    }

    private func arc(angle: Angle) -> some View {
        let width = max(1.5, size * 0.13)
        return ZStack {
            Circle()
                .stroke(SupervisionTokens.line.color, lineWidth: width)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(SupervisionTokens.running.color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(angle)
        }
        .padding(width / 2)
    }
}

/// The dot that goes round the ring of work left running after a turn,
/// once every `turnDuration` at an even pace, centered on the ring's line
/// (`StateGlyphGeometry.orbitRadius`) and drawn in `orbitInk`.
///
/// The turn is one repeating animation the render server runs, as the
/// running arc's is (`RunningArc`), rather than a body drawn again every
/// frame. Under Reduce Motion the dot stays at `restingAngle`, the ring's
/// upper right, where it still marks the glyph apart from the rest it
/// rides on.
struct StateGlyphOrbit: View {
    let geometry: StateGlyphGeometry
    let ring: StateGlyphGeometry.Ring
    let isTurning: Bool
    @State private var isAtFullTurn = false

    /// Where the dot rests, and where each turn starts: clockwise from the
    /// top.
    static let restingAngle = Angle.degrees(45)
    /// How long one turn takes.
    static let turnDuration: TimeInterval = 2.4

    /// The turn while the dot goes round; none under Reduce Motion, so the
    /// dot is drawn still.
    static func turn(isTurning: Bool) -> Animation? {
        isTurning ? .linear(duration: turnDuration).repeatForever(autoreverses: false) : nil
    }

    var body: some View {
        dot(angle: Self.restingAngle + .degrees(isTurning && isAtFullTurn ? 360 : 0))
            .animation(Self.turn(isTurning: isTurning), value: isAtFullTurn)
            .onAppear { isAtFullTurn = isTurning }
            .onChange(of: isTurning) { _, isTurning in
                isAtFullTurn = isTurning
            }
    }

    /// The dot at the top of the ring, turned about the glyph's center.
    private func dot(angle: Angle) -> some View {
        let diameter = geometry.orbitDotDiameter(on: ring)
        return Circle()
            .fill(geometry.orbitInk.color)
            .frame(width: diameter, height: diameter)
            .offset(y: -geometry.orbitRadius(on: ring))
            .frame(width: geometry.size, height: geometry.size)
            .rotationEffect(angle)
    }
}
