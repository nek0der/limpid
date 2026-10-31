// SupervisionTokens.swift
// Limpid — the supervision UI's colors, chosen so text reaches 4.5:1 and marks 3:1.

import AppKit
import SwiftUI

/// An sRGB color, kept as numbers so its contrast can be worked out and
/// tested without drawing anything.
struct SRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `color` in sRGB, as `appearance` draws it. `nil` for a color with no
    /// sRGB form (a pattern).
    init?(_ color: NSColor, in appearance: NSAppearance) {
        var converted: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            converted = color.usingColorSpace(.sRGB)
        }
        guard let converted else { return nil }
        self.init(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent)
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// This color moved `amount` (0 to 1) of the way to black.
    func darkened(by amount: Double) -> Self {
        Self(red: red * (1 - amount), green: green * (1 - amount), blue: blue * (1 - amount))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

enum ContrastRatio {
    /// The WCAG contrast ratio of two colors, from 1 to 21.
    static func between(_ first: SRGB, _ second: SRGB) -> Double {
        let lighter = max(first.luminance, second.luminance)
        let darker = min(first.luminance, second.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// What body text needs against its background.
    static let text = 4.5
    /// What an icon needs against its background.
    static let icon = 3.0
}

/// One token's light and dark values.
struct ThemedColor: Equatable, Sendable {
    let light: SRGB
    let dark: SRGB
    /// One dynamic color per token, made once with it; AppKit resolves it
    /// per appearance as it draws. Made once rather than each time it is
    /// asked for: two dynamic colors made apart compare unequal, so a view
    /// handed a fresh one read as changed on every pass and was drawn
    /// again, every row of a scrolling list included.
    let nsColor: NSColor
    /// `nsColor` as SwiftUI draws it, the same value each time.
    let color: Color

    init(light: UInt32, dark: UInt32) {
        let light = SRGB(light)
        let dark = SRGB(dark)
        self.light = light
        self.dark = dark
        nsColor = NSColor(name: nil) { appearance in
            (appearance.isDark ? dark : light).nsColor
        }
        color = Color(nsColor: nsColor)
    }

    func value(isDark: Bool) -> SRGB {
        isDark ? dark : light
    }

    /// The two values are the token; the colors are made from them.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.light == rhs.light && lhs.dark == rhs.dark
    }
}

/// One token drawn as ink laid over whatever surface is under it, rather
/// than as a surface of its own: black in light and white in dark, at an
/// opacity per appearance. The review's diff stands on a surface that
/// follows the background opacity, and an opaque fill there would stand out
/// as a solid band with transparency on.
struct ThemedOverlay: Equatable, Sendable {
    let lightOpacity: Double
    let darkOpacity: Double
    /// Made once, as `ThemedColor`'s are, so it compares equal to itself.
    let nsColor: NSColor
    let color: Color

    init(lightOpacity: Double, darkOpacity: Double) {
        self.lightOpacity = lightOpacity
        self.darkOpacity = darkOpacity
        // The ink's own values, so the color drawn and the contrast worked
        // out (`value(over:isDark:)`) cannot part.
        let ink = Self.ink
        nsColor = NSColor(name: nil) { appearance in
            appearance.isDark
                ? ink.dark.nsColor.withAlphaComponent(darkOpacity)
                : ink.light.nsColor.withAlphaComponent(lightOpacity)
        }
        color = Color(nsColor: nsColor)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lightOpacity == rhs.lightOpacity && lhs.darkOpacity == rhs.darkOpacity
    }

    private static let ink = ThemedColor(light: 0x000000, dark: 0xFFFFFF)

    /// The token laid over `background`, as it reads on an opaque surface;
    /// what its contrast is worked out from.
    func value(over background: SRGB, isDark: Bool) -> SRGB {
        let ink = Self.ink.value(isDark: isDark)
        let opacity = isDark ? darkOpacity : lightOpacity
        func mix(_ top: Double, _ bottom: Double) -> Double {
            top * opacity + bottom * (1 - opacity)
        }
        return SRGB(
            red: mix(ink.red, background.red),
            green: mix(ink.green, background.green),
            blue: mix(ink.blue, background.blue)
        )
    }

}

/// A row's fill: an opaque token, or ink laid over what is under it.
enum RowFill: Equatable, Sendable {
    case solid(ThemedColor)
    case overlay(ThemedOverlay)

    /// Follows the appearance it is drawn in.
    var color: Color {
        switch self {
        case let .solid(token): token.color
        case let .overlay(token): token.color
        }
    }

    /// The fill as it reads over `ground`; what its contrast is worked out
    /// from. An opaque token covers the ground.
    func value(over ground: SRGB, isDark: Bool) -> SRGB {
        switch self {
        case let .solid(token): token.value(isDark: isDark)
        case let .overlay(token): token.value(over: ground, isDark: isDark)
        }
    }
}

/// What a floating panel's rows stand on: the opaque `popover` token while
/// transparency is off or reduced, or the material otherwise. The
/// panel's surface says which (`FloatingPanelSurface`), and its rows take
/// their selected and hovered fills from it, since the opaque fills that
/// read on `popover` all but vanish on the material.
enum PopoverGround: Equatable, Sendable {
    case opaque
    case material

    /// The ground a panel's surface is filled with: opaque while
    /// transparency is off or reduced, as every surface follows the
    /// appearance settings, the material otherwise.
    init(reducesTransparency: Bool) {
        self = reducesTransparency ? .opaque : .material
    }

    /// The selected row: the one the keys are on, or a chosen filter.
    var selection: RowFill {
        switch self {
        case .opaque: .solid(SupervisionTokens.selection)
        case .material: .overlay(SupervisionTokens.popoverSelection)
        }
    }

    /// A hovered row.
    var hover: RowFill {
        switch self {
        case .opaque: .solid(SupervisionTokens.hover)
        case .material: .overlay(SupervisionTokens.popoverHover)
        }
    }

    /// The quiet well a field or a command sits in, which on the opaque
    /// ground has always been `hover`'s gray.
    var well: RowFill {
        switch self {
        case .opaque: .solid(SupervisionTokens.hover)
        case .material: .overlay(SupervisionTokens.popoverWell)
        }
    }

    /// The edge around a group of rows and the rule between them, as in the
    /// notification history's sources: the window's `line` on the opaque
    /// ground, ink on the material, where `line` would read as a color of
    /// its own over whatever the glass takes up.
    var groupRule: RowFill {
        switch self {
        case .opaque: .solid(SupervisionTokens.line)
        case .material: .overlay(SupervisionTokens.popoverRule)
        }
    }

    /// The edge drawn inside the selected row, on the material only: there
    /// the fill can stand only so far off it before the text on it drops
    /// under 4.5:1, so the edge is what makes the row the keys are on
    /// plain to see, and it costs the text nothing. On the opaque ground the
    /// fill alone reads, so no edge is drawn.
    var selectionEdge: ThemedOverlay? {
        switch self {
        case .opaque: nil
        case .material: SupervisionTokens.popoverSelectionEdge
        }
    }
}

/// How opaque the window's ground and its surfaces are filled. One
/// rule for both, so a box drawn on either mixes with the glass as the
/// ground under it does.
enum SupervisionSurfaceOpacity {
    /// The background opacity while transparency is on; 1 while it is off
    /// or reduced, or for a surface that is always opaque (the changes
    /// panel laid over the session).
    static func resolve(backgroundOpacity: Double, reducesTransparency: Bool, isOpaque: Bool = false) -> Double {
        isOpaque || reducesTransparency ? 1 : backgroundOpacity
    }
}

extension View {
    /// The selected row's edge on its ground (`PopoverGround.selectionEdge`),
    /// drawn inside `shape`, which is the row's fill's.
    func popoverSelectionEdge(isSelected: Bool, in shape: some InsettableShape) -> some View {
        modifier(PopoverSelectionEdge(isSelected: isSelected, shape: shape))
    }
}

private struct PopoverSelectionEdge<EdgeShape: InsettableShape>: ViewModifier {
    let isSelected: Bool
    let shape: EdgeShape
    @Environment(\.popoverSurface.ground) private var ground

    func body(content: Content) -> some View {
        content.overlay {
            if isSelected, let edge = ground.selectionEdge {
                shape.strokeBorder(edge.color, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// How a list's rows show the row the keys or the pointer are on.
enum RowHighlight: Equatable, Sendable {
    /// The ground's fills (`PopoverGround.selection`, `.hover`), with the
    /// edge the material asks for: Limpid's own popovers and lists.
    case ground
    /// The system menu's: one accent fill for the row the keys or the
    /// pointer are on, its words white on it, and no edge, as the menus
    /// beside the menu bar extra draw theirs. The pointer selects the row
    /// as the keys do, and leaving it leaves no row lit.
    case systemMenu

    /// The fill of the selected row, where it is not the ground's.
    var selection: Color? {
        switch self {
        case .ground: nil
        case .systemMenu: Color(nsColor: .selectedContentBackgroundColor)
        }
    }

    /// The color every word on the selected row takes, where the fill is
    /// strong enough to ask for one; `nil` keeps each word its own.
    var selectedText: Color? {
        switch self {
        case .ground: nil
        case .systemMenu: Color(nsColor: .selectedMenuItemTextColor)
        }
    }

    /// Whether the pointer over a row selects it, rather than tinting it
    /// with the ground's hover fill.
    var pointerSelects: Bool {
        self == .systemMenu
    }
}

/// What a panel's words are drawn in: the supervision tokens, or the
/// system's label colors, which adapt to what shows through the glass.
enum PopoverInk: Equatable, Sendable {
    /// `SupervisionTokens.text`, `muted`, and `line`: Limpid's own panels,
    /// whose material is thick enough for a fixed value to keep its
    /// contrast.
    case tokens
    /// The system's primary and secondary label colors: the menu bar
    /// extra's window is the Liquid Glass MenuBarExtra draws, far more
    /// see-through than a menu's material, so over a light window it is a
    /// mid gray that no fixed gray, light or dark, reads on. The system's
    /// labels are vibrant, mixed with what is behind the glass, as the
    /// menus beside it draw theirs.
    case vibrant

    /// Words that carry the row: a title, a command.
    var text: Color {
        switch self {
        case .tokens: SupervisionTokens.text.color
        case .vibrant: .primary
        }
    }

    /// Quiet words: a heading, a place, a time, a note.
    var muted: Color {
        switch self {
        case .tokens: SupervisionTokens.muted.color
        case .vibrant: .secondary
        }
    }

    /// A control's edge.
    var line: Color {
        switch self {
        case .tokens: SupervisionTokens.line.color
        case .vibrant: .primary.opacity(0.25)
        }
    }

    /// A warning's words. Amber words read on Limpid's own panels, but on
    /// the menu's glass only the system's labels do, so there the warning's
    /// amber icon carries the state alone.
    var warningText: Color {
        switch self {
        case .tokens: SupervisionTokens.waitingText.color
        case .vibrant: .primary
        }
    }
}

/// Which surface a view is drawn on: one of Limpid's own floating panels,
/// on the ground its surface chose, or the menu bar extra's window, which
/// is the system's menu. One value, because its ground, the way its rows
/// light, and its words' ink all follow from that one fact: a view that
/// read one of them and not another would draw tokens that cannot be read
/// on the menu's glass, or the menu's accent in a panel of ours.
enum PopoverSurface: Equatable, Sendable {
    /// A Limpid panel or list, on the ground its surface says.
    case limpid(PopoverGround)
    /// The menu bar extra's window.
    case systemMenu

    /// What the rows stand on. The menu's window is the system's material
    /// whatever the app's transparency, and turns opaque only under Reduce
    /// Transparency, so its buttons and wells take the fills laid over a
    /// ground rather than the opaque ones the material all but matches.
    var ground: PopoverGround {
        switch self {
        case let .limpid(ground): ground
        case .systemMenu: .material
        }
    }

    /// How the rows light the selected one.
    var rowHighlight: RowHighlight {
        switch self {
        case .limpid: .ground
        case .systemMenu: .systemMenu
        }
    }

    /// What the words are drawn in. The state colors (amber, red) stay
    /// tokens on either.
    var ink: PopoverInk {
        switch self {
        case .limpid: .tokens
        case .systemMenu: .vibrant
        }
    }
}

extension EnvironmentValues {
    /// The surface a view is drawn on. Limpid's opaque ground outside a
    /// panel, so a row drawn elsewhere, or a panel whose surface never
    /// said, keeps the opaque fills and the tokens it had.
    @Entry var popoverSurface: PopoverSurface = .limpid(.opaque)
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// The supervision UI's colors. Text never uses `faint`, which is for
/// rules and disabled controls; amber and red text use their `…Text`
/// tokens and green text `added`, each tuned to 4.5:1, and text on an
/// amber or red fill uses `on…`.
enum SupervisionTokens {

    // MARK: Surfaces

    static let page = ThemedColor(light: 0xE8EAEE, dark: 0x111215)
    /// The window's ground: the gaps between the surfaces, the title bar,
    /// the rails, and the status band. A step darker than `window` in both
    /// appearances, so each surface stands apart from it.
    static let well = ThemedColor(light: 0xE3E6EB, dark: 0x0D0E10)
    static let window = ThemedColor(light: 0xFFFFFF, dark: 0x1B1C20)
    static let sidebar = ThemedColor(light: 0xF3F4F6, dark: 0x222328)
    static let column = ThemedColor(light: 0xFAFAFB, dark: 0x1F2024)
    static let selection = ThemedColor(light: 0xE2E6ED, dark: 0x30333A)
    /// A rail button that is pressed, or whose panel is open. The rails
    /// stand on `well`, which `selection` all but matches in light, so
    /// there the button takes the surfaces' white; in dark `selection`
    /// already stands off the well.
    static let railSelection = ThemedColor(light: 0xFFFFFF, dark: 0x30333A)
    static let hover = ThemedColor(light: 0xECEEF2, dark: 0x292B30)
    /// A hovered segment on a segmented control's track, which is `hover`:
    /// `selection` all but matches that track (1.08:1 in light), so this
    /// stands about 1.3:1 off it in both appearances, darker in light and
    /// lighter in dark.
    static let segmentHover = ThemedColor(light: 0xCCD1DA, dark: 0x3D4047)
    static let line = ThemedColor(light: 0xE1E4E9, dark: 0x313339)
    /// The popovers' and menus' one surface while transparency is off
    /// or reduced: white in light, a step above the window in dark, so a
    /// panel over the terminal still stands off it. Its dark value is the
    /// sidebar's rather than a lighter gray such as #2A2C31, on which
    /// `hover`, `selection`, and `line` all but vanish: selection is all that marks
    /// the row the keys are on in the palette and the lists. Over the
    /// sidebar in dark the popover is told apart by its edge and shadows,
    /// as white over the white window is in light.
    /// On this ground the rows keep `selection` and `hover`.
    static let popover = ThemedColor(light: 0xFFFFFF, dark: 0x222328)
    /// The selected and hovered rows on a popover's other ground: the
    /// material it keeps while transparency is on, as every surface
    /// follows the appearance settings (`PopoverGround`). The material takes
    /// its color from what is behind it, about #F1F1F1 in light and #2C2C2E
    /// in dark, which the opaque `selection` and `hover` all but match
    /// (1.11:1 and 1.03:1 in light, 1.10:1 and 1.02:1 in dark), so there
    /// they are ink laid over it, standing off it by the same step whatever
    /// it resolves to. How far is bounded by the text on them: `muted`
    /// reaches only about 5.2:1 on the material itself, and every text
    /// token must keep 4.5:1 on a selected row, so selection stands
    /// about 1.14:1 off the material in light and 1.15:1 in dark.
    static let popoverSelection = ThemedOverlay(lightOpacity: 0.06, darkOpacity: 0.045)
    /// A hovered row on the material: half the selection's step or so,
    /// about 1.07:1 off it in light and 1.10:1 in dark, so the chosen row
    /// still reads stronger than the one under the pointer.
    static let popoverHover = ThemedOverlay(lightOpacity: 0.03, darkOpacity: 0.03)
    /// The well a field or a command sits in on the material, as quiet as
    /// a hovered row: it only sets the words apart from the panel.
    static let popoverWell = ThemedOverlay(lightOpacity: 0.03, darkOpacity: 0.03)
    /// The 1pt edge inside a selected row on the material, laid over the
    /// selection's fill: about 1.42:1 off the material in light and 1.57:1
    /// in dark, where the fill alone stands only about 1.15:1 off it. No
    /// text sits on it, so it can be stronger than the fill.
    static let popoverSelectionEdge = ThemedOverlay(lightOpacity: 0.10, darkOpacity: 0.10)
    /// The edge around a group of rows on the material and the rules inside
    /// it (`PopoverGround.groupRule`): a step under the selected row's edge,
    /// so the row the keys are on still stands out within its group. No
    /// text sits on it.
    static let popoverRule = ThemedOverlay(lightOpacity: 0.08, darkOpacity: 0.08)
    /// The well an inline rename's field stands in, laid under the label
    /// and a few points past it (`InlineRenameEditingStyle`), as quiet as
    /// `popoverWell`: it marks where the field is, and gives its selection
    /// and its first glyph room, on whatever the label stands on (a tab's
    /// face, a sidebar row's fill, a pane header's wash). Ink rather than a
    /// color of its own for that reason; `text` keeps well above 4.5:1 on it
    /// on every one of those grounds.
    static let renameWell = ThemedOverlay(lightOpacity: 0.04, darkOpacity: 0.06)
    /// The popovers' material as measured with transparency on: never
    /// drawn, only what the contrast of a mark or a fill laid on the
    /// material is worked out against.
    static let popoverMaterial = ThemedColor(light: 0xF1F1F1, dark: 0x2C2C2E)

    // MARK: Text

    static let text = ThemedColor(light: 0x1C1E22, dark: 0xE7E8EB)
    static let muted = ThemedColor(light: 0x5F656E, dark: 0x9A9FA8)
    /// Rules and disabled controls only, never text.
    static let faint = ThemedColor(light: 0x9A9FA7, dark: 0x80858E)

    // MARK: States

    /// Unread's blue: the counts, chips, rules, and dots that say unread
    /// beside words. A fixed blue rather than the person's accent, so they
    /// read the same whatever accent was picked. The unread state glyph is
    /// the exception: its ring and dot take the accent (`accentIcon`), told
    /// from the stopped and waiting discs by being a ring, not by its
    /// color, so a red or orange accent still reads as unread.
    static let unread = ThemedColor(light: 0x2C6EE0, dark: 0x5B93F0)
    /// Text in that blue (an unread count): a step darker in light and
    /// lighter in dark, so it reads at 4.5:1 on the window, a hovered fill,
    /// and a selected one, where the ring's blue reaches only an icon's 3:1.
    static let unreadText = ThemedColor(light: 0x1F5FC9, dark: 0x6E9FF3)
    /// A count filled in that blue (the rails' unread and unviewed counts):
    /// the deeper blue in both appearances, since the dark one would not
    /// hold its white figures at 4.5:1.
    static let unreadCount = ThemedColor(light: 0x2C6EE0, dark: 0x2C6EE0)
    /// The decision bar's ground over unread turns: the blue's soft fill,
    /// as amber and red have theirs.
    static let unreadFill = ThemedColor(light: 0xE4ECFB, dark: 0x223150)
    /// The accent's soft tone under a drop target's ring
    /// (`SupervisionDropMark`): the accent at this much over the window, a
    /// tint that marks the target without competing with its ring. Taken
    /// from the person's accent rather than fixed, as the ring is, and left
    /// translucent, so what the target holds still reads under it.
    static let dropTargetFillOpacity: Double = 0.14
    /// The accent's faintest tone, behind every line of a project a dragged
    /// tab is over (`SupervisionProjectDropMark`): under half the row's
    /// tone, so the row the tab would land on stands out inside it.
    static let dropProjectFillOpacity: Double = 0.06
    /// A button or a bordered control that is off: the whole control at
    /// half, its words and its edge alike, as the window's buttons fade.
    /// A sheet's field keeps its own, lighter fade
    /// (`LimpidLayout.Supervision.sheetFieldDisabledOpacity`).
    static let disabledOpacity: Double = 0.5
    /// The "⌘⏎" beside a primary button's title: a little under the title,
    /// so the key reads as a hint to it (`PrimaryKeyHintLabel`).
    static let keyHintOpacity: Double = 0.75
    static let onUnreadCount = ThemedColor(light: 0xFFFFFF, dark: 0xFFFFFF)
    /// The running glyph's moving arc; its track is `line`, neutral like
    /// the state (blue is for unread and unviewed only).
    static let running = ThemedColor(light: 0x686E78, dark: 0x9A9FA8)
    /// The one amber of a wait, in each appearance: the frame,
    /// the dots, and the icons drawn in it. It reaches an icon's 3:1 on
    /// every surface it sits on, the light well and selection included.
    static let waiting = ThemedColor(light: 0xC06A06, dark: 0xF0A040)
    /// Words in amber. A step darker than `waiting` in light, so they read
    /// at 4.5:1 where the amber reaches only an icon's 3:1; in dark the
    /// amber itself reads as text.
    static let waitingText = ThemedColor(light: 0x965300, dark: 0xF0A040)
    /// The soft amber ground of a wait's chips and of warnings: the
    /// attention count and the decision bar's tag draw `waitingText` on it with a 1pt edge in
    /// `waiting` (`NeedsAttentionCountStyle`, `DecisionBarTagStyle`).
    /// Nothing with words on it is filled in `waiting` itself: the strong
    /// amber under dark letters reads as a dark block.
    static let waitingFill = ThemedColor(light: 0xFDF0DF, dark: 0x3A2B18)
    /// A button standing inside a state's soft fill, at rest, hovered, and
    /// pressed, with its edge: opaque neutrals, so the button keeps its own
    /// color whatever the fill's hue. Each step moves further from the rest
    /// face, and `text` keeps 4.5:1 on the strongest.
    static let stateFillButton = ThemedColor(light: 0xFFFFFF, dark: 0x30333A)
    static let stateFillButtonHover = ThemedColor(light: 0xECEEF2, dark: 0x3D4047)
    static let stateFillButtonPressed = ThemedColor(light: 0xE2E6ED, dark: 0x4A4D55)
    static let stateFillButtonEdge = ThemedColor(light: 0xCCD1DA, dark: 0x4A4D55)
    /// The needs-input glyph's disc ("?"), wherever it is drawn: the
    /// sidebar, the tabs, Needs Attention, the history, the cards. The
    /// lightest amber on which a white mark still reaches 3:1 for
    /// marks (3.01:1; a step lighter in red or green falls under it), the
    /// same in both appearances: lighter than `waiting` in light, a little
    /// deeper than it in dark, where the white would not read on the
    /// brighter amber. The mark is a sign, not words to read, as a badge's
    /// letters are (`badgeForeground`).
    static let waitingGlyph = ThemedColor(light: 0xDA7E11, dark: 0xDA7E11)
    /// The "?" on that disc: white in both appearances.
    static let onWaiting = ThemedColor(light: 0xFFFFFF, dark: 0xFFFFFF)
    /// The disc's edge, for where its fill stands under 3:1 off a surface:
    /// in light, on a selected row (2.41:1), it takes its own color
    /// darkened just far enough for 3:1 on every light surface, as the
    /// Claude badge's edge does; in dark the fill stands 4.2:1 off
    /// everything, so the edge is the fill and draws nothing.
    /// `SelectionEdgeRule.color(waitingGlyph, on: selection)`, written out.
    static let waitingGlyphEdge = ThemedColor(light: 0xC06F0F, dark: 0xDA7E11)
    static let stopped = ThemedColor(light: 0xD4433A, dark: 0xEE6A61)
    /// Lighter than the red disc in dark, so a stop's reason reads on a
    /// selected sidebar row (4.80:1).
    static let stoppedText = ThemedColor(light: 0xB3261E, dark: 0xF27D75)
    static let stoppedFill = ThemedColor(light: 0xFBE7E5, dark: 0x3C2221)
    /// The stopped glyph's "!", and the ✕ of a failing check on the same
    /// red: white in both appearances, as the waiting disc's "?" is. A
    /// sign rather than words, so it is held to 3:1 for marks, which
    /// white reaches on the dark red too (3.06:1).
    static let onStopped = ThemedColor(light: 0xFFFFFF, dark: 0xFFFFFF)

    // MARK: Diffs

    /// Lines added and removed, as a receipt counts them ("+94 −2"): text
    /// tones of their own, so a count of changes is not read as a state
    /// (no state is drawn in green). They are the green and red that read
    /// as text: in light, a green dark enough to read on a selected row
    /// too (4.66:1), and the red of `stoppedText`.
    /// Both reach 4.5:1 on every ground a count sits on. The green also
    /// draws passing checks, in the hover card and on the corner of a pull
    /// request's mark, since a check's result is not a state.
    static let added = ThemedColor(light: 0x1D7436, dark: 0x4CBF6C)
    static let removed = ThemedColor(light: 0xB3261E, dark: 0xF27D75)

    /// What stands in, in the split diff, for a line the other column does
    /// not have: a quiet ground, and diagonal lines over it. The lines stand
    /// about 2:1 off that ground in both appearances: quieter than the code
    /// opposite, whose absence they mark, and under an icon's 3:1, so they
    /// never read as content, yet clear of the 1.6:1 at which they showed
    /// only zoomed in.
    static let diffPlaceholder = ThemedOverlay(lightOpacity: 0.06, darkOpacity: 0.12)
    static let diffHatch = ThemedOverlay(lightOpacity: 0.30, darkOpacity: 0.25)

    /// The ground of a comment's card in the diff, over the diff's surface.
    static let reviewCard = ThemedOverlay(lightOpacity: 0.05, darkOpacity: 0.05)

    /// A toast's link on the toast's inverted surface.
    static let toastLink = ThemedColor(light: 0x8AB4FF, dark: 0x1D4FAE)

    // MARK: Agents

    /// The Claude badge's fill: the orange of Claude's mark (the fill of
    /// the logo claude.ai serves as its icon, Anthropic's primary accent),
    /// the same in both appearances, so the badge reads as Claude's. Badge
    /// fills only: as text on white it reaches 3.12:1, under 4.5:1.
    static let claude = ThemedColor(light: 0xD97757, dark: 0xD97757)
    /// The Codex badge's fill: a blue from the gradient on Codex's app
    /// icon (#B1A7FF to #3941FF), taken far enough along it that white
    /// letters reach 4.5:1 (4.58:1). Codex has a mark of its own, so the
    /// badge takes its blue rather than OpenAI's black, whose mark turns
    /// white in dark mode and would have taken dark letters there. The
    /// same in both appearances.
    static let codex = ThemedColor(light: 0x5D60FF, dark: 0x5D60FF)
    /// The edge inside each badge, for a fill that stands under 3:1 off a
    /// surface it sits on. Claude's orange does in light (2.49:1 on a
    /// selected row), so there it takes its own color darkened just far
    /// enough for 3:1 on every light surface, which stays close to the
    /// fill; in dark it stands 4:1 off everything. Codex's blue does in
    /// dark (2.76:1 on a selected row), so there it takes its own color
    /// lightened to 3:1; in light it stands 3.66:1 off everything. Where an
    /// edge is the fill, it draws nothing. The edges are
    /// `SelectionEdgeRule.color(fill, on: selection)`, written out so the
    /// badge needs no work at draw time.
    static let claudeEdge = ThemedColor(light: 0xC36B4E, dark: 0xD97757)
    static let codexEdge = ThemedColor(light: 0x5D60FF, dark: 0x676AFF)
    /// The letters on an agent badge: white, in both appearances, so the
    /// fill reads as the brand's color rather than one muddied by dark
    /// letters. On Codex's blue that is
    /// 4.58:1. On Claude's orange it is 3.12:1: the two letters are a mark
    /// that says whose badge it is, not words to read, so they are held to
    /// 3:1 for marks, as a logotype is; reaching 4.5:1 would have
    /// meant darkening the orange to brown.
    static let badgeForeground = ThemedColor(light: 0xFFFFFF, dark: 0xFFFFFF)
    /// A closed source's mark in the notification history: the badge's
    /// fill under its white letters, and the shell's or the place's glyph;
    /// also a turn card's ✓ for a check run on part of the suite
    /// (`ReceiptRun.Role.quietMark`).
    /// Quieter than `muted`, so the source reads as gone, yet held to
    /// 3:1 for marks, which `faint` is not: white on the light `faint` was
    /// 2.66:1. The same gray in both appearances: white on it is 3.71:1,
    /// and it stands 3.28:1 off the history's light material and 3.71:1
    /// off its opaque white, 3.76:1 and 4.23:1 off the dark ones. Fixed
    /// rather than raised under Increase Contrast, as every token is, so it
    /// meets the bar without it.
    static let closedMark = ThemedColor(light: 0x80858E, dark: 0x80858E)

    // MARK: Conversation identity

    /// The colors that tell a worktree's active conversations apart, so a
    /// pane strip tab and the Changes panel's cards of one conversation can
    /// be matched: green, purple, teal, pink, yellow, and white (dark) or
    /// ink (light). A conversation holds its index while it stays active
    /// (`ConversationIdentityRule`), so the order is fixed and a color is only
    /// ever added at the end. The bar they are drawn as
    /// (`ConversationIdentityBar`) stands before a badge whose
    /// conversation every place also names in words, and is hidden from
    /// VoiceOver, so they are held to 2:1 off a card and a tab rather than
    /// the 3:1 a mark that carries meaning alone needs. They stand apart by
    /// their OKLab distance, which follows how far apart colors look, and
    /// none is near the unread blue.
    static let conversationIdentity: [ThemedColor] = [
        ThemedColor(light: 0x44C462, dark: 0x4FC46B),
        ThemedColor(light: 0xA678F3, dark: 0xA77BF0),
        ThemedColor(light: 0x2ABEC6, dark: 0x2FC0C8),
        ThemedColor(light: 0xEF6CB9, dark: 0xEC6FB8),
        ThemedColor(light: 0xCDA911, dark: 0xEBCB45),
        ThemedColor(light: 0x3A3D44, dark: 0xD9DCE2)
    ]

    // MARK: Terminal

    /// What a terminal's lines sit on outside the terminal itself (the last
    /// lines on an all projects card): the window's white in light, a step
    /// darker than the window in dark.
    static let terminal = ThemedColor(light: 0xFFFFFF, dark: 0x17181B)

    /// What dims the window under a sheet laid over it. Translucent, so it
    /// is a `Color` rather than a `ThemedColor`: nothing is read on it.
    static let scrim = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
            : NSColor(srgbRed: 20 / 255, green: 22 / 255, blue: 28 / 255, alpha: 0.3)
    })
}

/// The primary button: the accent the person chose, with a label that
/// reads on it at 4.5:1. A deep accent (blue, purple, pink, red, the
/// system default: white already reaches 3:1) keeps the white label macOS
/// buttons use, its fill darkened just enough; a light accent (yellow,
/// orange, green) takes the dark label instead, since darkening it that far
/// would turn it brown.
enum PrimaryButtonRule {
    static let lightLabel = SRGB(0xFFFFFF)
    static let darkLabel = SRGB(0x1C1E22)

    static func style(onAccent accent: SRGB) -> (fill: SRGB, label: SRGB) {
        if ContrastRatio.between(accent, lightLabel) >= ContrastRatio.icon {
            return (AccentDarkening.darkened(accent, until: ContrastRatio.text, against: lightLabel), lightLabel)
        }
        if ContrastRatio.between(accent, darkLabel) >= ContrastRatio.text {
            return (accent, darkLabel)
        }
        return (AccentDarkening.darkened(accent, until: ContrastRatio.text, against: lightLabel), lightLabel)
    }
}

/// An icon or ring drawn in the accent (a focus ring, a dropdown's check,
/// the update icon): the accent itself where it reaches an icon's 3:1 on
/// every surface such a mark is drawn on, else moved away from them until
/// it does (`ContrastMove`). Worked out against all of them, not the
/// window alone: a ring stands on a selected row, a field's well, the
/// rails' ground, and a popover's material, and a yellow accent darkened
/// for white stood only 2.46:1 off a selected row.
enum AccentIconRule {
    static func color(_ accent: SRGB, on grounds: [SRGB]) -> SRGB {
        ContrastMove.away(accent, from: grounds, until: ContrastRatio.icon)
    }

    /// The surfaces an accent mark is drawn on in one appearance: each
    /// surface token, the popovers' material, and a selected and a hovered
    /// row on it.
    static func grounds(isDark: Bool) -> [SRGB] {
        typealias Tokens = SupervisionTokens
        let surfaces = [
            Tokens.page, Tokens.well, Tokens.window, Tokens.sidebar, Tokens.column, Tokens.selection,
            Tokens.railSelection, Tokens.hover, Tokens.popover, Tokens.terminal, Tokens.popoverMaterial
        ]
        let material = Tokens.popoverMaterial.value(isDark: isDark)
        return surfaces.map { $0.value(isDark: isDark) } + [
            Tokens.popoverSelection.value(over: material, isDark: isDark),
            Tokens.popoverHover.value(over: material, isDark: isDark)
        ]
    }
}

/// A color moved away from the grounds it is drawn on until it stands
/// `ratio` off each of them: darkened on light grounds, lightened on dark
/// ones, in small steps that end at black or white, which every ground
/// stands well off. Unchanged when it already does.
enum ContrastMove {
    static func away(_ color: SRGB, from grounds: [SRGB], until ratio: Double) -> SRGB {
        guard let first = grounds.first else { return color }
        func reaches(_ candidate: SRGB) -> Bool {
            grounds.allSatisfy { ContrastRatio.between(candidate, $0) >= ratio }
        }
        let isLight = ContrastRatio.between(first, SRGB(0x000000)) > ContrastRatio.between(first, SRGB(0xFFFFFF))
        var result = color
        var step = 0.0
        while !reaches(result), step < 1 {
            step = min(step + 0.02, 1)
            result = isLight
                ? color.darkened(by: step)
                : SRGB(
                    red: color.red + (1 - color.red) * step,
                    green: color.green + (1 - color.green) * step,
                    blue: color.blue + (1 - color.blue) * step
                )
        }
        return result
    }
}

/// A project's mark: white letters, as macOS draws on a colored control,
/// on the project's palette color darkened until they read at 4.5:1.
/// Every mark carries the same white, so no one mark's letters look
/// muddied beside the others'. Darkening a light warm color or a pale green
/// that far turns it brown or gray (amber, saffron, mint), so those three
/// take a deep color of their own hue instead, picked by hand; the fill
/// still tells the projects apart.
enum ProjectMarkRule {
    static let label = PrimaryButtonRule.lightLabel

    /// The hand-picked fills, by palette index: amber, mint, saffron. Each
    /// keeps its color's hue and passes 4.5:1 under white.
    static let keptHueFills: [Int: SRGB] = [
        3: SRGB(0xA16800),
        13: SRGB(0x157F54),
        15: SRGB(0xB35900)
    ]

    /// The mark's fill for a project whose color resolves to `color`;
    /// `paletteIndex` is `nil` for a project with no palette color, which
    /// takes the accent.
    static func fill(_ color: SRGB, paletteIndex: Int?) -> SRGB {
        if let paletteIndex, let kept = keptHueFills[paletteIndex] {
            return kept
        }
        return AccentDarkening.darkened(color, until: ContrastRatio.text, against: label)
    }
}

enum AccentDarkening {
    /// `color` darkened in small steps until it reaches `ratio` against
    /// `other`; unchanged when it already does.
    static func darkened(_ color: SRGB, until ratio: Double, against other: SRGB) -> SRGB {
        var result = color
        var step = 0.0
        while ContrastRatio.between(result, other) < ratio, step < 1 {
            step += 0.02
            result = color.darkened(by: step)
        }
        return result
    }
}

/// The edge of a selection filled in the accent on a track (the segmented
/// picker's pill). The fill tells the chosen segment from the others, and a
/// light accent (yellow, orange, green) on the light track differs from it
/// by a shade the eye can miss, under the 3:1 a state needs. The edge
/// is the fill itself when it already stands 3:1 off the track; else the
/// fill darkened on a light track, or lightened on a dark one, until it
/// does. Either way ends at black or white, which a track stands well off.
enum SelectionEdgeRule {
    static func color(_ fill: SRGB, on track: SRGB) -> SRGB {
        ContrastMove.away(fill, from: [track], until: ContrastRatio.icon)
    }
}

extension SupervisionTokens {
    /// The segmented picker's pill edge for an accent already resolved in
    /// one appearance: the pill is the primary button's fill, on the
    /// `hover` track (`SelectionEdgeRule`).
    static func segmentedPillEdge(onAccent accent: SRGB, isDark: Bool) -> SRGB {
        SelectionEdgeRule.color(PrimaryButtonRule.style(onAccent: accent).fill, on: hover.value(isDark: isDark))
    }

    /// `segmentedPillEdge(onAccent:isDark:)` for `accent`, in whatever
    /// appearance it is drawn in.
    static func segmentedPillEdge(_ accent: AccentColor) -> Color {
        let accentColor = NSColor(LimpidColor.accent(for: accent))
        return Color(nsColor: NSColor(name: nil) { appearance in
            guard let resolved = SRGB(accentColor, in: appearance) else { return accentColor }
            return segmentedPillEdge(onAccent: resolved, isDark: appearance.isDark).nsColor
        })
    }

    /// The primary button's fill and label for `accent`, in whatever
    /// appearance they are drawn in.
    static func primaryButton(_ accent: AccentColor) -> (fill: Color, label: Color) {
        let accentColor = NSColor(LimpidColor.accent(for: accent))
        func style(_ appearance: NSAppearance) -> (fill: SRGB, label: SRGB)? {
            SRGB(accentColor, in: appearance).map(PrimaryButtonRule.style(onAccent:))
        }
        let fill = NSColor(name: nil) { appearance in
            style(appearance)?.fill.nsColor ?? accentColor
        }
        let label = NSColor(name: nil) { appearance in
            style(appearance)?.label.nsColor ?? .white
        }
        return (Color(nsColor: fill), Color(nsColor: label))
    }

    /// A project's mark fill for `paletteIndex`, in whatever appearance it
    /// is drawn in (`ProjectMarkRule`).
    static func projectMarkFill(paletteIndex: Int?) -> Color {
        let color = NSColor(LimpidColor.paletteColor(paletteIndex))
        return Color(nsColor: NSColor(name: nil) { appearance in
            SRGB(color, in: appearance).map { ProjectMarkRule.fill($0, paletteIndex: paletteIndex) }?.nsColor ?? color
        })
    }

    /// The accent for an icon or ring, readable at 3:1 on every surface it
    /// is drawn on (`AccentIconRule`), in whatever appearance it is drawn
    /// in.
    static func accentIcon(_ accent: AccentColor) -> Color {
        accentIcon(color: LimpidColor.accent(for: accent))
    }

    /// `accentIcon(_:)` for an accent already resolved to a color, as
    /// `\.limpidAccent` carries it.
    static func accentIcon(color accent: Color) -> Color {
        let accentColor = NSColor(accent)
        return Color(nsColor: NSColor(name: nil) { appearance in
            guard let resolved = SRGB(accentColor, in: appearance) else { return accentColor }
            return AccentIconRule.color(resolved, on: AccentIconRule.grounds(isDark: appearance.isDark)).nsColor
        })
    }
}
