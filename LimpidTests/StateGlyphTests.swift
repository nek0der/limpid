// StateGlyphTests.swift
// Limpid — the state glyphs as their legend draws them, in light and dark, with Increase Contrast and Reduce Motion.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@MainActor
struct StateGlyphTests {
    private typealias Tokens = SupervisionTokens
    private typealias Geometry = StateGlyphGeometry

    // MARK: - VoiceOver

    /// Each glyph keeps the name VoiceOver reads for it.
    @Test(arguments: [
        (StateGlyph.Kind.needsApproval, "Needs approval"),
        (.needsAnswer, "Needs answer"),
        (.needsResponse, "Needs response"),
        (.stopped, "Stopped"),
        (.unread, "Unread"),
        (.unreadWorkingAfterTurn, "Unread, working in the background"),
        (.running, "Running"),
        (.idle, "Idle"),
        (.workingAfterTurn, "Working in the background"),
        (.unknown, "Unknown")
    ])
    func eachState_keepsItsName(kind: StateGlyph.Kind, name: String) {
        #expect(kind.name.resolved(in: Locale(identifier: "en")) == name)
    }

    // MARK: - Reduce Motion

    /// The running arc turns, and under Reduce Motion it is drawn still.
    @Test func theRunningArc_turnsOnlyWithoutReduceMotion() {
        #expect(RunningArc.turn(isTurning: true) != nil)
        #expect(RunningArc.turn(isTurning: false) == nil)
    }

    /// The dot of work after a turn goes round, and under Reduce Motion it
    /// rests at the ring's upper right.
    @Test func theOrbitingDot_turnsOnlyWithoutReduceMotion() {
        #expect(StateGlyphOrbit.turn(isTurning: true) != nil)
        #expect(StateGlyphOrbit.turn(isTurning: false) == nil)
        #expect(StateGlyphOrbit.restingAngle == .degrees(45))
    }

    // MARK: - What the environment says

    /// The glyph draws what its environment asks for: Reduce Motion stops
    /// the arc, Increase Contrast reaches the face, and a lit row's ink
    /// stands in for the accent.
    @Test func theEnvironment_reachesTheFace() {
        func face(reduceMotion: Bool = false, contrast: ColorSchemeContrast = .standard, ink: Color? = nil) -> StateGlyphFace {
            StateGlyph(kind: .unread, inkOnAccentFill: ink)
                .face(isReduceMotionOn: reduceMotion, contrast: contrast, accent: .purple)
        }
        #expect(face().isTurning)
        #expect(!face(reduceMotion: true).isTurning)
        #expect(!face().isContrastIncreased)
        #expect(face(contrast: .increased).isContrastIncreased)
        #expect(face(ink: .white).unreadInk == .white)
    }

    /// Without a lit row the unread glyph is drawn in the accent the
    /// environment carries, moved to an icon's contrast as the focus ring's
    /// is, for every accent in light and dark.
    @Test(arguments: AccentColor.allCases)
    func theUnreadInk_isTheAccentAtAnIconsContrast(_ accent: AccentColor) throws {
        let color = LimpidColor.accent(for: accent)
        let ink = StateGlyph(kind: .unread).face(isReduceMotionOn: false, contrast: .standard, accent: color).unreadInk
        for resolved in try accent.resolvedInBothAppearances() {
            let appearance = try #require(NSAppearance(named: resolved.appearance))
            let drawn = try #require(SRGB(NSColor(ink), in: appearance))
            let wanted = AccentIconRule.color(resolved.color, on: AccentIconRule.grounds(isDark: resolved.isDark))
            #expect(abs(drawn.luminance - wanted.luminance) < 0.002, "\(accent) in \(resolved.appearance.rawValue)")
            for ground in AccentIconRule.grounds(isDark: resolved.isDark) {
                #expect(ContrastRatio.between(drawn, ground) >= ContrastRatio.icon, "\(accent) on \(ground)")
            }
        }
    }

    // MARK: - Geometry

    /// The rings: unread at 1.6 of the disc's 14 units, idle a 1pt
    /// hairline under it, and both 0.5pt heavier with Increase Contrast,
    /// so the idle ring reaches 1.5pt and takes `muted`.
    @Test func theRings_thickenWithIncreaseContrast() {
        let standard = Geometry(size: 15, isContrastIncreased: false)
        let increased = Geometry(size: 15, isContrastIncreased: true)
        #expect(abs(standard.ringWidth(.unread) - 15 * 1.6 / 14) < 0.001)
        #expect(standard.ringWidth(.idle) == 1)
        #expect(increased.ringWidth(.idle) == 1.5)
        #expect(increased.ringWidth(.unread) > standard.ringWidth(.unread))
        #expect(standard.ringWidth(.unread) > standard.ringWidth(.idle))
        #expect(standard.idleInk == Tokens.faint)
        #expect(increased.idleInk == Tokens.muted)
    }

    /// Every part of "!" and "?" stays inside the disc they are drawn
    /// on; the marks scale with the glyph, so this holds at every size.
    @Test func theMarks_stayInsideTheirDisc() {
        let center = CGPoint(x: 8, y: 8)
        let radius = Geometry.discUnits / 2
        let bar = Geometry.exclamationBar
        let stroke = Geometry.questionStrokeUnits / 2
        let extremes = [
            CGPoint(x: bar.minX, y: bar.minY), CGPoint(x: bar.maxX, y: bar.maxY),
            CGPoint(x: Geometry.exclamationDotCenter.x, y: Geometry.exclamationDotCenter.y + Geometry.markDotRadius),
            CGPoint(x: Geometry.questionDotCenter.x, y: Geometry.questionDotCenter.y + Geometry.markDotRadius),
            // The question mark's hook, at its left and its top.
            CGPoint(x: Geometry.questionStart.x - stroke, y: Geometry.questionStart.y),
            CGPoint(x: Geometry.questionArcCenter.x, y: Geometry.questionArcCenter.y - Geometry.questionArcRadius - stroke)
        ]
        for extreme in extremes {
            #expect(hypot(extreme.x - center.x, extreme.y - center.y) < radius, "\(extreme)")
        }
    }

    // MARK: - Drawing

    /// Each state drawn in light and dark: a red disc with a white "!", an
    /// amber disc with a white "?", an accent ring around an accent dot,
    /// and a faint ring with nothing inside.
    @Test(arguments: [false, true])
    func eachGlyph_drawsTheLegendsShape(isDark: Bool) throws {
        let stopped = try Self.render(.stopped, isDark: isDark)
        Self.expect(stopped, at: (8, 6.4), is: Tokens.onStopped.value(isDark: isDark), "the stopped glyph's bar")
        Self.expect(stopped, at: (8, 11.6), is: Tokens.onStopped.value(isDark: isDark), "the stopped glyph's dot")
        Self.expect(stopped, at: (4.5, 8), is: Tokens.stopped.value(isDark: isDark), "the stopped disc")
        #expect(Tokens.onStopped.value(isDark: isDark) == SRGB(0xFFFFFF))

        let waiting = try Self.render(.needsApproval, isDark: isDark)
        Self.expect(waiting, at: (8, 12), is: Tokens.onWaiting.value(isDark: isDark), "the waiting glyph's dot")
        Self.expect(waiting, at: (4.5, 8), is: Tokens.waitingGlyph.value(isDark: isDark), "the waiting disc")
        Self.expect(waiting, at: (8, 9.4), is: Tokens.onWaiting.value(isDark: isDark), "the question mark's stem")
        // The hook turns over the top, not under: white at its top, and
        // the disc where an arc drawn the other way would pass.
        let top = (Double(Geometry.questionArcCenter.x), Double(Geometry.questionArcCenter.y - Geometry.questionArcRadius))
        Self.expect(waiting, at: top, is: Tokens.onWaiting.value(isDark: isDark), "the top of the question mark's hook")
        Self.expect(waiting, at: (6.98, 7.93), is: Tokens.waitingGlyph.value(isDark: isDark), "under the hook")

        let ink = SRGB(0x2C6EE0)
        let unread = try Self.render(.unread, isDark: isDark, unreadInk: ink)
        Self.expect(unread, at: (8, 8), is: ink, "the unread dot")
        Self.expect(unread, at: (8, 1.8), is: ink, "the unread ring")
        #expect(Self.alpha(unread, at: (8, 3.8)) < 0.05, "between the unread ring and its dot")

        let idle = try Self.render(.idle, isDark: isDark)
        Self.expect(idle, at: (8, 1.45), is: Tokens.faint.value(isDark: isDark), "the idle ring")
        #expect(Self.alpha(idle, at: (8, 8)) < 0.05, "inside the idle ring")

        let unknown = try Self.render(.unknown, isDark: isDark)
        #expect(Self.alpha(unknown, at: (8, 8)) < 0.05, "inside the unknown ring")
    }

    /// Work left running after a turn keeps the rest it rides on, the idle
    /// ring or the unread ring and its dot, and adds a dot centered on the
    /// ring's line. Drawn still, as under Reduce Motion, the dot sits at
    /// `restingAngle`, and shows at the compact size a tab draws as well as
    /// at a row's, with and without Increase Contrast.
    @Test(arguments: [false, true], [LimpidLayout.Supervision.stateGlyphSize, LimpidLayout.Supervision.stateGlyphCompactSize])
    func workAfterATurn_addsADotOnTheRing(isDark: Bool, size: CGFloat) throws {
        for isContrastIncreased in [false, true] {
            let geometry = Geometry(size: size, isContrastIncreased: isContrastIncreased)
            let dot = geometry.orbitInk.value(isDark: isDark)
            func dotCenter(on ring: Geometry.Ring) -> (Double, Double) {
                let radius = Double(geometry.orbitRadius(on: ring) / geometry.unit)
                let angle = StateGlyphOrbit.restingAngle.radians
                return (8 + radius * sin(angle), 8 - radius * cos(angle))
            }
            let what = "at \(size)pt, contrast \(isContrastIncreased)"

            let working = try Self.render(.workingAfterTurn, isDark: isDark, size: size, isContrastIncreased: isContrastIncreased)
            Self.expect(working, at: dotCenter(on: .idle), is: dot, "the dot on the idle ring \(what)")
            #expect(Self.alpha(working, at: (8, 8)) < 0.05, "inside the ring \(what)")

            let ink = SRGB(0x2C6EE0)
            let unread = try Self.render(
                .unreadWorkingAfterTurn, isDark: isDark, size: size, isContrastIncreased: isContrastIncreased, unreadInk: ink
            )
            Self.expect(unread, at: dotCenter(on: .unread), is: dot, "the dot on the unread ring \(what)")
            Self.expect(unread, at: (8, 8), is: ink, "the unread dot \(what)")
        }
    }

    /// The dot sits on the middle of the ring's line, stands out of the
    /// ring it rides on, follows the ring's width so Increase Contrast
    /// enlarges it, and keeps a size a tab's 11pt mark still shows on the
    /// idle hairline.
    @Test func theOrbitingDot_isCenteredOnItsRing_andWiderThanIt() {
        let compact = Geometry(size: LimpidLayout.Supervision.stateGlyphCompactSize, isContrastIncreased: false)
        let increased = Geometry(size: LimpidLayout.Supervision.stateGlyphCompactSize, isContrastIncreased: true)
        for ring in [Geometry.Ring.idle, .unread] {
            #expect(compact.orbitRadius(on: ring) == (compact.size - compact.ringWidth(ring)) / 2)
            #expect(compact.orbitDotDiameter(on: ring) >= 1.6 * compact.ringWidth(ring))
            #expect(increased.orbitDotDiameter(on: ring) >= compact.orbitDotDiameter(on: ring))
        }
        #expect(compact.orbitDotDiameter(on: .idle) >= 2)
    }

    /// The dot's ink, the body text's, stands at least 2:1 from the ring it
    /// rides on in both appearances, the faint idle ring and the `muted` one
    /// Increase Contrast draws alike.
    @Test(arguments: [false, true])
    func theOrbitingDot_standsApartFromTheIdleRing(isDark: Bool) {
        for isContrastIncreased in [false, true] {
            let least = 2.0
            let geometry = Geometry(size: 15, isContrastIncreased: isContrastIncreased)
            let dot = geometry.orbitInk.value(isDark: isDark)
            let ring = geometry.idleInk.value(isDark: isDark)
            #expect(ContrastRatio.between(dot, ring) >= least, "contrast \(isContrastIncreased): \(dot.hexBytes) on \(ring.hexBytes)")
        }
        #expect(Geometry(size: 15, isContrastIncreased: false).orbitInk == Tokens.text)
        #expect(Geometry(size: 15, isContrastIncreased: true).orbitInk == Tokens.text)
    }

    /// Unknown draws a dashed ring in `muted` at every size the glyph is
    /// drawn: its dashes and gaps both show around the ring, so it never
    /// reads as the idle ring's solid line, nor as an empty slot.
    @Test(arguments: [false, true], [LimpidLayout.Supervision.stateGlyphSize, LimpidLayout.Supervision.stateGlyphCompactSize])
    func theUnknownGlyph_isADashedRing(isDark: Bool, size: CGFloat) throws {
        let pixels = try Self.render(.unknown, isDark: isDark, size: size)
        let geometry = Geometry(size: size, isContrastIncreased: false)
        // The ring's middle line, in the square's units.
        let radius = (size - geometry.ringWidth(.unknown)) / 2 / geometry.unit
        let samples = (0..<96).map { step in
            let angle = Double(step) / 96 * 2 * .pi
            return Self.pixel(pixels, at: (8 + Double(radius) * cos(angle), 8 + Double(radius) * sin(angle)))
        }
        let inked = samples.filter { $0.alpha > 0.6 }
        let clear = samples.filter { $0.alpha < 0.1 }
        #expect(inked.count >= 16, "dashes at \(size)pt: \(inked.count)")
        #expect(clear.count >= 16, "gaps at \(size)pt: \(clear.count)")
        let muted = Tokens.muted.value(isDark: isDark)
        let solid = inked.filter { $0.alpha > 0.95 }
        #expect(!solid.isEmpty)
        for pixel in solid {
            #expect(abs(pixel.color.luminance - muted.luminance) < 0.03, "\(pixel.color.hexBytes)")
        }
    }

    /// The unknown ring's dashes and gaps share its length equally, and
    /// Increase Contrast thickens it as it does the idle ring.
    @Test func theUnknownDashes_splitTheRing_andThickenWithIncreaseContrast() {
        for isContrastIncreased in [false, true] {
            let geometry = Geometry(size: 15, isContrastIncreased: isContrastIncreased)
            let width = geometry.ringWidth(.unknown)
            #expect(width == geometry.ringWidth(.idle))
            let dash = geometry.unknownDash
            #expect(dash.count == 2)
            // Drawn with round caps, each dash shows a line's width longer
            // than its pattern, which the gap gives back.
            let shownDash = dash[0] + width
            let shownGap = dash[1] - width
            #expect(abs(shownDash - shownGap) < 0.001)
            let length = CGFloat.pi * (15 - width)
            #expect(abs((dash[0] + dash[1]) * CGFloat(Geometry.unknownDashCount) - length) < 0.001)
        }
        #expect(Geometry(size: 15, isContrastIncreased: false).unknownInk == Tokens.muted)
    }

    /// At the compact size a tab draws, "!" keeps the gap between its bar
    /// and its dot, and "?" its hook, stem, and dot, in both appearances.
    @Test(arguments: [false, true])
    func theMarks_stayLegibleAtTheCompactSize(isDark: Bool) throws {
        let size = LimpidLayout.Supervision.stateGlyphCompactSize
        let white = Tokens.onStopped.value(isDark: isDark)
        let stopped = try Self.render(.stopped, isDark: isDark, size: size)
        Self.expect(stopped, at: (8, 6.4), is: white, "the bar at \(size)pt")
        Self.expect(stopped, at: (8, 9.9), is: Tokens.stopped.value(isDark: isDark), "the gap at \(size)pt")
        Self.expect(stopped, at: (8, 11.6), is: white, "the dot at \(size)pt")
        let waiting = try Self.render(.needsAnswer, isDark: isDark, size: size)
        let top = (Double(Geometry.questionArcCenter.x), Double(Geometry.questionArcCenter.y - Geometry.questionArcRadius))
        Self.expect(waiting, at: top, is: Tokens.onWaiting.value(isDark: isDark), "the hook at \(size)pt")
        Self.expect(waiting, at: (8, 9.4), is: Tokens.onWaiting.value(isDark: isDark), "the stem at \(size)pt")
        Self.expect(waiting, at: (8, 10.6), is: Tokens.waitingGlyph.value(isDark: isDark), "the gap at \(size)pt")
        Self.expect(waiting, at: (8, 12), is: Tokens.onWaiting.value(isDark: isDark), "the dot at \(size)pt")
    }

    /// A folded project heading draws its marks at that compact size: the
    /// face sizes itself, so a frame around a full-size glyph would not.
    @Test(arguments: [SessionRowFact.Glyph.needsAnswer, .stopped, .running])
    func aFoldedHeadingsMarks_drawAtTheCompactSize(glyph: SessionRowFact.Glyph) {
        let face = SidebarProjectHeaderView.mark(glyph).stateGlyph
            .face(isReduceMotionOn: true, contrast: .standard, accent: .blue)
        #expect(face.size == LimpidLayout.Supervision.stateGlyphCompactSize)
    }

    /// An accent that shares the stopped disc's red still reads as unread
    /// rather than stopped: the unread glyph is open between its ring and
    /// its dot, where the stopped disc is filled.
    @Test(arguments: [false, true])
    func aRedAccent_stillDiffersFromStopped_byItsShape(isDark: Bool) throws {
        let red = Tokens.stopped.value(isDark: isDark)
        let unread = try Self.render(.unread, isDark: isDark, unreadInk: red)
        let stopped = try Self.render(.stopped, isDark: isDark)
        #expect(Self.alpha(unread, at: (4.5, 8)) < 0.05)
        #expect(Self.alpha(stopped, at: (4.5, 8)) > 0.95)
    }

    /// A gray accent (macOS's Graphite, which the default accent follows)
    /// still tells unread from idle: the unread glyph has its dot, the idle
    /// ring is empty inside.
    @Test(arguments: [false, true])
    func aGrayAccent_stillDiffersFromIdle_byItsDot(isDark: Bool) throws {
        let gray = AccentIconRule.color(SRGB(0x8C8C8C), on: AccentIconRule.grounds(isDark: isDark))
        let unread = try Self.render(.unread, isDark: isDark, unreadInk: gray)
        let idle = try Self.render(.idle, isDark: isDark)
        Self.expect(unread, at: (8, 8), is: gray, "the unread dot")
        #expect(Self.alpha(idle, at: (8, 8)) < 0.05)
    }

    /// Increase Contrast widens the idle ring into what was empty, and
    /// draws it in `muted`.
    @Test(arguments: [false, true])
    func increaseContrast_widensAndDeepensTheIdleRing(isDark: Bool) throws {
        let standard = try Self.render(.idle, isDark: isDark)
        let increased = try Self.render(.idle, isDark: isDark, isContrastIncreased: true)
        let inside = (8.0, 2.2)
        #expect(Self.alpha(standard, at: inside) < 0.3)
        Self.expect(increased, at: inside, is: Tokens.muted.value(isDark: isDark), "the widened idle ring")
    }

    // MARK: - Rendering

    private static let scale: CGFloat = 4

    /// `kind` drawn at `size`, four times over.
    private static func render(
        _ kind: StateGlyph.Kind,
        isDark: Bool,
        size: CGFloat = LimpidLayout.Supervision.stateGlyphSize,
        isContrastIncreased: Bool = false,
        unreadInk: SRGB = SRGB(0x2C6EE0)
    ) throws -> Pixels {
        let face = StateGlyphFace(
            kind: kind,
            size: size,
            isTurning: false,
            isContrastIncreased: isContrastIncreased,
            unreadInk: Color(nsColor: unreadInk.nsColor)
        )
        .environment(\.colorScheme, isDark ? .dark : .light)
        let renderer = ImageRenderer(content: face)
        renderer.scale = scale
        return try Pixels(#require(renderer.cgImage), unit: size / Geometry.discUnits * scale)
    }

    /// An image's pixels in sRGB, eight bits a channel, premultiplied.
    struct Pixels {
        let width: Int
        /// One of the square's units, in pixels.
        let unit: CGFloat
        let bytes: [UInt8]

        init(_ image: CGImage, unit: CGFloat) throws {
            width = image.width
            self.unit = unit
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let drawn = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            try #require(drawn)
            self.bytes = bytes
        }

        /// The pixel `x` across and `y` down: its color with the alpha
        /// taken out, and its alpha.
        func at(x: Int, y: Int) -> (color: SRGB, alpha: Double) {
            let offset = (y * width + x) * 4
            let alpha = Double(bytes[offset + 3]) / 255
            func channel(_ index: Int) -> Double {
                alpha > 0 ? Double(bytes[offset + index]) / 255 / alpha : 0
            }
            return (SRGB(red: channel(0), green: channel(1), blue: channel(2)), alpha)
        }
    }

    /// The pixel at a point of the glyph's 16-unit square.
    private static func pixel(_ pixels: Pixels, at point: (Double, Double)) -> (color: SRGB, alpha: Double) {
        pixels.at(
            x: Int(((point.0 - 1) * pixels.unit).rounded(.down)),
            y: Int(((point.1 - 1) * pixels.unit).rounded(.down))
        )
    }

    private static func alpha(_ pixels: Pixels, at point: (Double, Double)) -> Double {
        pixel(pixels, at: point).alpha
    }

    /// The pixel is opaque and within a step of `expected` in each channel.
    private static func expect(
        _ pixels: Pixels,
        at point: (Double, Double),
        is expected: SRGB,
        _ what: String
    ) {
        let (color, alpha) = pixel(pixels, at: point)
        #expect(alpha > 0.95, "\(what): alpha \(alpha)")
        let channels = [(color.red, expected.red), (color.green, expected.green), (color.blue, expected.blue)]
        for (drawn, wanted) in channels {
            #expect(abs(drawn - wanted) < 0.03, "\(what): \(color.hexBytes) for \(expected.hexBytes)")
        }
    }
}
