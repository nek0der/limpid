// SupervisionTokensTests.swift
// Limpid — the supervision colors meet their contrast floors in light and dark, on every surface they are drawn on,
// and each is one value however often it is asked for.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

struct SupervisionTokensTests {
    private typealias Tokens = SupervisionTokens

    /// A foreground token on a background token, named for the failure
    /// message.
    struct Pair {
        let name: String
        let foreground: ThemedColor
        let background: ThemedColor

        init(_ name: String, _ foreground: ThemedColor, _ background: ThemedColor) {
            self.name = name
            self.foreground = foreground
            self.background = background
        }

        func ratio(isDark: Bool) -> Double {
            ContrastRatio.between(foreground.value(isDark: isDark), background.value(isDark: isDark))
        }
    }

    /// Text and the backgrounds it sits on: 4.5:1.
    private static let textPairs: [Pair] = [
        Pair("text on window", Tokens.text, Tokens.window),
        Pair("muted on well", Tokens.muted, Tokens.well),
        Pair("unread count on window", Tokens.unreadText, Tokens.window),
        Pair("unread count on hover", Tokens.unreadText, Tokens.hover),
        Pair("unread count on selection", Tokens.unreadText, Tokens.selection),
        Pair("text on sidebar", Tokens.text, Tokens.sidebar),
        Pair("text on selection", Tokens.text, Tokens.selection),
        Pair("muted on window", Tokens.muted, Tokens.window),
        Pair("muted on sidebar, and on a file header", Tokens.muted, Tokens.sidebar),
        Pair("muted on selection", Tokens.muted, Tokens.selection),
        Pair("amber text on window", Tokens.waitingText, Tokens.window),
        Pair("amber text on sidebar", Tokens.waitingText, Tokens.sidebar),
        // The decision bar's Approval tag and the title bar's attention
        // count are soft chips of their family, on their own fill (the
        // bar's ground for a tag), as the pane strip's exit mark is.
        Pair("amber text on amber fill: Approval tag, attention count", Tokens.waitingText, Tokens.waitingFill),
        Pair("amber text on selection", Tokens.waitingText, Tokens.selection),
        Pair("red text on window", Tokens.stoppedText, Tokens.window),
        Pair("red text on sidebar", Tokens.stoppedText, Tokens.sidebar),
        Pair("red text on selection", Tokens.stoppedText, Tokens.selection),
        Pair("red text on red fill: Stopped tag, exit mark", Tokens.stoppedText, Tokens.stoppedFill),
        // A toast is an inverted surface, drawn in the text color.
        Pair("toast link on a toast", Tokens.toastLink, Tokens.text),
        // Codex's badge letters reach the text ratio as well; Claude's are
        // held to the marks' (below).
        Pair("Codex badge letters", Tokens.badgeForeground, Tokens.codex),
        Pair("muted on a terminal's lines", Tokens.muted, Tokens.terminal),
        Pair("muted on hover, and on a discarded hunk header", Tokens.muted, Tokens.hover),
        // The review tab's stacked diff: a file's header and a hunk's, and
        // a discarded hunk's, each with muted words and counts on it.
        Pair("muted on a hunk header", Tokens.muted, Tokens.column),
        Pair("text on a hunk header", Tokens.text, Tokens.column),
        Pair("red text on a hunk header", Tokens.stoppedText, Tokens.column),
        // The "Running · n" chip's words, on the chip's own window fill.
        Pair("running on window", Tokens.running, Tokens.window),
        // The decision bar over unread turns: its words, the receipt's
        // additions and removals, and a failed check.
        Pair("text on unread fill", Tokens.text, Tokens.unreadFill),
        Pair("muted on unread fill", Tokens.muted, Tokens.unreadFill),
        Pair("red text on unread fill", Tokens.stoppedText, Tokens.unreadFill),
        // A receipt's counts, wherever the bar shows one: over unread
        // turns and at rest.
        Pair("additions on unread fill", Tokens.added, Tokens.unreadFill),
        Pair("removals on unread fill", Tokens.removed, Tokens.unreadFill),
        Pair("additions on sidebar, and on a file header", Tokens.added, Tokens.sidebar),
        Pair("removals on sidebar, and on a file header", Tokens.removed, Tokens.sidebar),
        Pair("additions on window", Tokens.added, Tokens.window),
        Pair("additions on selection", Tokens.added, Tokens.selection),
        Pair("removals on window", Tokens.removed, Tokens.window),
        // The bar's words over a wait and a stop.
        Pair("text on amber fill", Tokens.text, Tokens.waitingFill),
        Pair("text on red fill", Tokens.text, Tokens.stoppedFill),
        Pair("muted on amber fill", Tokens.muted, Tokens.waitingFill),
        Pair("muted on red fill", Tokens.muted, Tokens.stoppedFill),
        Pair("unread text on unread fill: Unread tag, unread-only count", Tokens.unreadText, Tokens.unreadFill),
        // A toast's words on its inverted box.
        Pair("toast words on a toast", Tokens.window, Tokens.text),
        // The popovers' opaque surface, with transparency off or reduced:
        // the palette, the history, the lists, and the approval card.
        Pair("text on popover", Tokens.text, Tokens.popover),
        Pair("muted on popover", Tokens.muted, Tokens.popover),
        Pair("red text on popover", Tokens.stoppedText, Tokens.popover),
        Pair("amber text on popover", Tokens.waitingText, Tokens.popover)
        // The review's quiet words (a fold's hidden lines, the file list's
        // headings and counts) are "muted on window" and, on a selected
        // file, "muted on selection"; its banners' words on the amber and
        // red grounds are the decision bar's "text on amber fill" and "text
        // on red fill". A comment card's (its title, place, and state) and
        // those on the row fills (the find bar, the preview's chips) are
        // below.
    ]

    /// Words on a ground laid over a surface (`ThemedOverlay`), named for
    /// the failure message.
    struct OverlayPair {
        let name: String
        let foreground: ThemedColor
        let overlay: ThemedOverlay
        let surface: ThemedColor

        init(_ name: String, _ foreground: ThemedColor, on overlay: ThemedOverlay, over surface: ThemedColor) {
            self.name = name
            self.foreground = foreground
            self.overlay = overlay
            self.surface = surface
        }

        func ratio(isDark: Bool) -> Double {
            let ground = overlay.value(over: surface.value(isDark: isDark), isDark: isDark)
            return ContrastRatio.between(foreground.value(isDark: isDark), ground)
        }
    }

    /// A comment card's words in the diff, and the stale note in the
    /// comments' preview, whose card is a lighter coat than this one.
    private static let overlayTextPairs: [OverlayPair] = [
        OverlayPair("muted on a comment card", Tokens.muted, on: Tokens.reviewCard, over: Tokens.window),
        OverlayPair("text on a comment card", Tokens.text, on: Tokens.reviewCard, over: Tokens.window),
        OverlayPair("amber text on a comment card", Tokens.waitingText, on: Tokens.reviewCard, over: Tokens.window),
        OverlayPair("amber text on a comment card on popover", Tokens.waitingText, on: Tokens.reviewCard, over: Tokens.popover),
        OverlayPair("muted on a comment card on popover", Tokens.muted, on: Tokens.reviewCard, over: Tokens.popover)
    ]

    /// Icons and the backgrounds they sit on: 3:1.
    private static let iconPairs: [Pair] = [
        // The "?" is a mark, held to 3:1 on its disc; the disc's edge
        // carries it off every surface it sits on.
        Pair("needs-input mark on its disc", Tokens.onWaiting, Tokens.waitingGlyph),
        // The stopped disc's white "!" is a mark too, as the "?" is.
        Pair("stopped mark on its disc", Tokens.onStopped, Tokens.stopped),
        Pair("needs-input disc's edge on window", Tokens.waitingGlyphEdge, Tokens.window),
        Pair("needs-input disc's edge on sidebar", Tokens.waitingGlyphEdge, Tokens.sidebar),
        Pair("needs-input disc's edge on hover", Tokens.waitingGlyphEdge, Tokens.hover),
        Pair("needs-input disc's edge on the terminal", Tokens.waitingGlyphEdge, Tokens.terminal),
        // The decision bar's tag edges and the attention count's ring, on
        // their own fill, which is also the bar's ground: the edge is what
        // makes them chips. The count's button turns to `hover` while it
        // is hovered or open. The review's banners carry their amber and
        // red in the icon, on the matching fill (`ReviewBanner.Tone`), and
        // the decision bar's top rule over unread turns is the unread ring.
        Pair("amber on amber fill: tag edge, count ring, warning icon", Tokens.waiting, Tokens.waitingFill),
        Pair("red on red fill: tag edge, error icon", Tokens.stopped, Tokens.stoppedFill),
        Pair("unread on unread fill: tag edge, count ring, rule", Tokens.unread, Tokens.unreadFill),
        Pair("unread-only count's ring on hover", Tokens.unread, Tokens.hover),
        Pair("stopped disc on window", Tokens.stopped, Tokens.window),
        Pair("stopped disc on sidebar", Tokens.stopped, Tokens.sidebar),
        // The fixed unread blue where it marks without words (a count's
        // ring, the decision bar's rule, a history row's dot). The unread
        // state glyph takes the accent instead (`StateGlyphTests`).
        Pair("unread blue mark on window", Tokens.unread, Tokens.window),
        Pair("unread blue mark on sidebar", Tokens.unread, Tokens.sidebar),
        Pair("unread blue mark on selection", Tokens.unread, Tokens.selection),
        // The idle ring under Increase Contrast (`StateGlyphGeometry.idleInk`).
        Pair("idle ring with Increase Contrast on window", Tokens.muted, Tokens.window),
        Pair("idle ring with Increase Contrast on sidebar", Tokens.muted, Tokens.sidebar),
        Pair("idle ring with Increase Contrast on selection", Tokens.muted, Tokens.selection),
        Pair("idle ring with Increase Contrast on hover", Tokens.muted, Tokens.hover),
        Pair("idle ring with Increase Contrast on popover", Tokens.muted, Tokens.popover),
        Pair("running arc on window", Tokens.running, Tokens.window),
        Pair("running arc on sidebar", Tokens.running, Tokens.sidebar),
        Pair("amber on window, and the attention count's ring there", Tokens.waiting, Tokens.window),
        Pair("amber on sidebar", Tokens.waiting, Tokens.sidebar),
        // A selected row's glyph, a tab's dot on a selected tab, and the
        // pane's frame on the terminal.
        Pair("needs-input disc's edge on selection", Tokens.waitingGlyphEdge, Tokens.selection),
        Pair("amber on selection", Tokens.waiting, Tokens.selection),
        Pair("amber on hover, and the attention count's ring there", Tokens.waiting, Tokens.hover),
        Pair("amber on well", Tokens.waiting, Tokens.well),
        Pair("amber on the terminal", Tokens.waiting, Tokens.terminal),
        // A tab's dot for output since it was last shown, on the session's
        // surface, the terminal's ground.
        Pair("tab's unread dot on the terminal", Tokens.muted, Tokens.terminal),
        // The two letters on Claude's orange are a mark, not words to read
        // (`SupervisionTokens.badgeForeground`).
        Pair("Claude badge letters", Tokens.badgeForeground, Tokens.claude),
        // A badge is told apart by its shape as much as its letters: where
        // a brand fill stands too close to a surface, its edge carries it.
        Pair("Claude badge's edge on window", Tokens.claudeEdge, Tokens.window),
        Pair("Codex badge's edge on window", Tokens.codexEdge, Tokens.window),
        Pair("Claude badge's edge on sidebar", Tokens.claudeEdge, Tokens.sidebar),
        Pair("Codex badge's edge on sidebar", Tokens.codexEdge, Tokens.sidebar),
        Pair("Claude badge's edge on selection", Tokens.claudeEdge, Tokens.selection),
        Pair("Codex badge's edge on selection", Tokens.codexEdge, Tokens.selection),
        Pair("Claude badge's edge on hover", Tokens.claudeEdge, Tokens.hover),
        Pair("Codex badge's edge on hover", Tokens.codexEdge, Tokens.hover),
        Pair("Claude badge's edge on popover", Tokens.claudeEdge, Tokens.popover),
        Pair("Codex badge's edge on popover", Tokens.codexEdge, Tokens.popover),
        Pair("unread blue mark on popover", Tokens.unread, Tokens.popover),
        Pair("stopped disc on popover", Tokens.stopped, Tokens.popover),
        Pair("needs-input disc's edge on popover", Tokens.waitingGlyphEdge, Tokens.popover),
        // The file list's chevrons, filter, and clear marks.
        Pair("muted marks on the review tab", Tokens.muted, Tokens.window)
    ]

    @Test(arguments: [false, true])
    func text_reachesFourAndAHalfToOne(isDark: Bool) {
        for pair in Self.textPairs {
            let ratio = pair.ratio(isDark: isDark)
            #expect(ratio >= ContrastRatio.text, "\(pair.name) in \(isDark ? "dark" : "light"): \(ratio)")
        }
    }

    @Test(arguments: [false, true])
    func textOnALaidOverGround_reachesFourAndAHalfToOne(isDark: Bool) {
        for pair in Self.overlayTextPairs {
            let ratio = pair.ratio(isDark: isDark)
            #expect(ratio >= ContrastRatio.text, "\(pair.name) in \(isDark ? "dark" : "light"): \(ratio)")
        }
    }

    /// The review's quiet words on the row fills it lays over a surface:
    /// the find bar on the review tab, and in the comments' preview a
    /// comment's span chip, on the card, on the popover. The fills are
    /// `LimpidColor`'s, resolved with their opacity, so a stronger one
    /// fails here.
    @Test(arguments: [false, true])
    @MainActor
    func mutedOnTheReviewsRowFills_reachesFourAndAHalfToOne(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        func laid(_ fill: Color, over ground: SRGB) throws -> SRGB {
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(fill).usingColorSpace(.sRGB)
            }
            let coat = try #require(resolved)
            let alpha = coat.alphaComponent
            return SRGB(
                red: coat.redComponent * alpha + ground.red * (1 - alpha),
                green: coat.greenComponent * alpha + ground.green * (1 - alpha),
                blue: coat.blueComponent * alpha + ground.blue * (1 - alpha)
            )
        }
        let muted = Tokens.muted.value(isDark: isDark)
        let mode = isDark ? "dark" : "light"
        let findBar = try laid(LimpidColor.rowActiveFill.opacity(0.5), over: Tokens.window.value(isDark: isDark))
        let card = try laid(LimpidColor.rowActiveFill.opacity(0.5), over: Tokens.popover.value(isDark: isDark))
        let chip = try laid(LimpidColor.rowHoverFill, over: card)
        for (name, ground) in [("find bar", findBar), ("preview card", card), ("span chip", chip)] {
            let ratio = ContrastRatio.between(muted, ground)
            #expect(ratio >= ContrastRatio.text, "muted on the \(name) in \(mode): \(ratio)")
        }
    }

    /// The split diff's placeholder for a missing line: its lines show
    /// (above 1.8:1, clear of the 1.6:1 at which they read only zoomed in)
    /// but stay under an icon's 3:1, so they never read as content; its
    /// ground stands off the diff's surface without becoming a band.
    @Test(arguments: [false, true])
    func theDiffsHatch_isSubtleButVisible(isDark: Bool) {
        let window = Tokens.window.value(isDark: isDark)
        let ground = Tokens.diffPlaceholder.value(over: window, isDark: isDark)
        let line = Tokens.diffHatch.value(over: ground, isDark: isDark)
        let lineOnGround = ContrastRatio.between(line, ground)
        let groundOnWindow = ContrastRatio.between(ground, window)
        let mode = isDark ? "dark" : "light"
        #expect(lineOnGround >= 1.8, "hatch on its ground in \(mode): \(lineOnGround)")
        #expect(lineOnGround < ContrastRatio.icon, "hatch on its ground in \(mode): \(lineOnGround)")
        #expect(groundOnWindow > 1.05, "ground on the diff in \(mode): \(groundOnWindow)")
        #expect(groundOnWindow < 1.5, "ground on the diff in \(mode): \(groundOnWindow)")
    }

    /// An overlay laid over a surface is the ink mixed in at its opacity:
    /// none leaves the surface, all of it is the ink.
    @Test func anOverlay_mixesItsInkIntoTheSurface() {
        let white = SRGB(0xFFFFFF)
        #expect(ThemedOverlay(lightOpacity: 0, darkOpacity: 0).value(over: white, isDark: false) == white)
        #expect(ThemedOverlay(lightOpacity: 1, darkOpacity: 1).value(over: white, isDark: false) == SRGB(0x000000))
        #expect(ThemedOverlay(lightOpacity: 1, darkOpacity: 1).value(over: SRGB(0x000000), isDark: true) == white)
    }

    @Test(arguments: [false, true])
    func icons_reachThreeToOne(isDark: Bool) {
        for pair in Self.iconPairs {
            let ratio = pair.ratio(isDark: isDark)
            #expect(ratio >= ContrastRatio.icon, "\(pair.name) in \(isDark ? "dark" : "light"): \(ratio)")
        }
    }

    /// The decision bar's tag is a soft chip of its family: the state's
    /// soft fill, its text tone, and an edge in the state's own color; at
    /// rest and while resuming, no fill and the `line` edge.
    @Test func theDecisionBarsTag_isASoftChipOfItsFamily() {
        let waiting = DecisionBarTagStyle.of(.waiting)
        #expect(waiting == DecisionBarTagStyle(fill: Tokens.waitingFill, label: Tokens.waitingText, edge: Tokens.waiting))
        let stopped = DecisionBarTagStyle.of(.stopped)
        #expect(stopped == DecisionBarTagStyle(fill: Tokens.stoppedFill, label: Tokens.stoppedText, edge: Tokens.stopped))
        let unread = DecisionBarTagStyle.of(.unread)
        #expect(unread == DecisionBarTagStyle(fill: Tokens.unreadFill, label: Tokens.unreadText, edge: Tokens.unread))
        for tone in [DecisionBarModel.Tone.muted, .done] {
            #expect(DecisionBarTagStyle.of(tone) == DecisionBarTagStyle(fill: nil, label: Tokens.muted, edge: Tokens.line))
        }
        // Their contrast is the tables' "Approval tag", "Stopped tag", and
        // "Unread tag" rows.
    }

    /// The title bar's attention count is the same soft chip: amber while
    /// something blocks, blue on unread only, both with the state's ring;
    /// at zero neither fill nor ring, in the muted tone.
    @Test func theAttentionCount_isASoftChipOfItsFamily() {
        let blocking = NeedsAttentionCountStyle.of(.blocking)
        #expect(blocking == NeedsAttentionCountStyle(fill: Tokens.waitingFill, label: Tokens.waitingText, edge: Tokens.waiting))
        let unreadOnly = NeedsAttentionCountStyle.of(.unreadOnly)
        #expect(unreadOnly == NeedsAttentionCountStyle(fill: Tokens.unreadFill, label: Tokens.unreadText, edge: Tokens.unread))
        #expect(NeedsAttentionCountStyle.of(.empty) == NeedsAttentionCountStyle(fill: nil, label: Tokens.muted, edge: nil))
        // Their contrast is the tables' "attention count" rows.
    }

    /// The needs-input disc is the lightest amber a white "?" reads on at
    /// 3:1, the same in both appearances: a step lighter in red or in
    /// green, and the mark falls under it.
    @Test(arguments: [false, true])
    func theNeedsInputDisc_isTheLightestAmberAWhiteMarkReadsOn(isDark: Bool) {
        let disc = Tokens.waitingGlyph.value(isDark: isDark)
        #expect(Tokens.onWaiting.value(isDark: isDark) == PrimaryButtonRule.lightLabel)
        #expect(disc == Tokens.waitingGlyph.value(isDark: !isDark))
        #expect(ContrastRatio.between(PrimaryButtonRule.lightLabel, disc) >= ContrastRatio.icon)
        let step = 1.0 / 255
        let redder = SRGB(red: disc.red + step, green: disc.green, blue: disc.blue)
        let greener = SRGB(red: disc.red, green: disc.green + step, blue: disc.blue)
        #expect(ContrastRatio.between(PrimaryButtonRule.lightLabel, redder) < ContrastRatio.icon)
        #expect(ContrastRatio.between(PrimaryButtonRule.lightLabel, greener) < ContrastRatio.icon)
    }

    /// The disc's edge is the selection rule's in light, where the disc
    /// stands under 3:1 off a selected row, and the disc itself in dark.
    @Test func theNeedsInputDiscsEdge_isTheSelectionRulesEdge() {
        let light = SelectionEdgeRule.color(Tokens.waitingGlyph.value(isDark: false), on: Tokens.selection.value(isDark: false))
        #expect(Tokens.waitingGlyphEdge.value(isDark: false).hexBytes == light.hexBytes)
        #expect(Tokens.waitingGlyphEdge.dark == Tokens.waitingGlyph.dark)
        #expect(ContrastRatio.between(Tokens.waitingGlyph.value(isDark: false), Tokens.selection.value(isDark: false)) < ContrastRatio.icon)
    }

    /// The badges wear the brands' colors, the same in light and dark, with
    /// white letters on both.
    @Test(arguments: [false, true])
    func anAgentBadge_wearsItsBrandColorWithWhiteLetters(isDark: Bool) {
        #expect(Tokens.claude.value(isDark: isDark) == SRGB(0xD97757))
        #expect(Tokens.codex.value(isDark: isDark) == SRGB(0x5D60FF))
        #expect(Tokens.badgeForeground.value(isDark: isDark) == PrimaryButtonRule.lightLabel)
    }

    /// An edge draws only where its fill stands under 3:1 off a surface:
    /// Claude's in light, Codex's in dark. Elsewhere it is the fill.
    @Test func aBadgesEdge_isTheFillWhereTheFillStandsOff() {
        #expect(Tokens.claudeEdge.dark == Tokens.claude.dark)
        #expect(Tokens.codexEdge.light == Tokens.codex.light)
        #expect(Tokens.claudeEdge.light != Tokens.claude.light)
        #expect(Tokens.codexEdge.dark != Tokens.codex.dark)
    }

    /// The written-out edges are the selection rule's, so a change to the
    /// selected row's color cannot leave them behind. Compared at the 8 bits
    /// a channel the written-out hex has.
    @Test func aBadgesEdge_isTheSelectionRulesEdge() {
        let claude = SelectionEdgeRule.color(Tokens.claude.value(isDark: false), on: Tokens.selection.value(isDark: false))
        let codex = SelectionEdgeRule.color(Tokens.codex.value(isDark: true), on: Tokens.selection.value(isDark: true))
        #expect(Tokens.claudeEdge.value(isDark: false).hexBytes == claude.hexBytes)
        #expect(Tokens.codexEdge.value(isDark: true).hexBytes == codex.hexBytes)
    }

    @Test(arguments: [false, true])
    func theWell_isAStepDarkerThanTheSurfaces(isDark: Bool) {
        let well = Tokens.well.value(isDark: isDark).luminance
        #expect(well < Tokens.window.value(isDark: isDark).luminance)
    }

    @Test(arguments: [false, true])
    func aRailCount_readsOnItsBlue(isDark: Bool) {
        let ratio = ContrastRatio.between(Tokens.onUnreadCount.value(isDark: isDark), Tokens.unreadCount.value(isDark: isDark))
        #expect(ratio >= ContrastRatio.text, "\(ratio)")
    }

    /// A token's color is one value, the same each time it is asked for: a
    /// new dynamic color each time compared unequal to the last, so every
    /// view handed one read as changed on every pass, and SwiftUI drew it
    /// again rather than keep what it had drawn.
    @Test func aTokensColor_isTheSameValueEachTime() {
        #expect(SupervisionTokens.text.color == SupervisionTokens.text.color)
        #expect(SupervisionTokens.waitingGlyph.color == SupervisionTokens.waitingGlyph.color)
        #expect(SupervisionTokens.reviewCard.color == SupervisionTokens.reviewCard.color)
        #expect(SupervisionTokens.text.nsColor === SupervisionTokens.text.nsColor)
    }
}
