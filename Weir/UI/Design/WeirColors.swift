// WeirColors.swift
// Weir — semantic color tokens as SwiftUI `Color` values used across the app.

import SwiftUI

/// Semantic colors for Weir, as SwiftUI `Color` values.
///
/// **Guidelines**:
/// - Accent colors look muted alone but pop through glass.
/// - State and status colors (waiting, stopped, unread, a check's pass)
///   are not here: they are `SupervisionTokens`, so every surface draws a
///   state in the one color it has.
/// - Only one accent color per screen (the "5% rule").
enum WeirColor {
    /// Resolves to the macOS System Accent the user has picked in
    /// System Settings → Appearance. Painted whenever Weir's own
    /// accent picker is on `AccentColor.default`, so a user who never
    /// opens our Settings still sees Weir follow their OS-wide
    /// choice (Blue, Multicolor, Graphite, …). Callers should reach
    /// for `accent(for:)` instead so they honor the user's Weir
    /// pick automatically.
    static var defaultAccent: Color {
        Color.accentColor
    }

    /// Resolves the user-chosen `AccentColor` to a concrete `Color`.
    /// `.default` falls back to `defaultAccent`; the named cases use
    /// their SwiftUI counterpart so the hue tracks macOS Tahoe's
    /// System Accent for the same name.
    static func accent(for choice: AccentColor) -> Color {
        choice.color ?? defaultAccent
    }

    /// A merged pull request. Its own token rather than a status color
    /// because merged is neither success nor warning: the
    /// work is finished and the branch is spent, which the forges
    /// themselves render in purple and users read that way.
    static let merged: Color = .purple

    /// Text and glyphs drawn on a solid saturated fill: the user's
    /// accent (selected segments, the Move button, the review's
    /// add-comment marker). The fill's own hue carries the meaning, so the mark on top stays neutral.
    static let onAccent: Color = .white

    /// Primary text.
    static let primaryText: Color = .primary

    /// Secondary text (60% opacity).
    static let secondaryText: Color = .secondary

    /// Row-state fills shared by the sidebar pills and the tab bar pills.
    /// Picking once here keeps the two strips visually in lockstep.
    /// The fill is the whole "selected" signal now that the pills carry
    /// no stroke, so it cannot go any subtler than this without the
    /// selection becoming hard to find.
    static let rowActiveFill: Color = .primary.opacity(0.08)
    static let rowHoverFill: Color = .primary.opacity(0.04)
    /// Hairline along the sidebar's trailing edge and around the
    /// floating glass capsule.
    static let glassHairline: Color = .primary.opacity(0.08)

    /// Opaque fills for the two navigation surfaces when transparency is
    /// reduced. macOS resolves `windowBackgroundColor` and
    /// `controlBackgroundColor` to the same value — measured on macOS 26,
    /// #FFFFFF in light and #1E1E1E in dark — so painting a sidebar with
    /// either leaves it the exact tone of the content beside it, with a
    /// hairline as the only separation. In light mode that reads as one
    /// undivided white surface.
    ///
    /// These step away from the content the way the system's own
    /// sidebars do, and in the same direction the glass tints run:
    /// darker in light, lighter in dark, with the sidebar one step
    /// further out than the review's file rail so the ramp reads
    /// sidebar → rail → content.
    static let sidebarSolidFill: Color = .init(
        light: Color(white: 0.94),
        dark: Color(white: 0.16)
    )
    static let reviewRailSolidFill: Color = .init(
        light: Color(white: 0.97),
        dark: Color(white: 0.14)
    )

    /// The two command buttons in the expired prompt cache panel. White on
    /// the light material, where the usual translucent gray turns muddy,
    /// and a lifted gray with a lighter edge on the dark one.
    static let promptCacheButtonFill: Color = .init(
        light: Color.white.opacity(0.9),
        dark: Color.white.opacity(0.10)
    )
    static let promptCacheButtonEdge: Color = .init(
        light: Color.black.opacity(0.14),
        dark: Color.white.opacity(0.22)
    )

    /// Background tint for a surface beside the review's diff (the file
    /// rail's pinned headings, earlier comments). Slightly lighter than
    /// the surface it stands on, so it reads as a distinct surface
    /// without using a hairline.
    static let reviewAsideBackground: Color = .init(
        light: Color.white.opacity(0.45),
        dark: Color.black.opacity(0.18)
    )

    /// Background tint for a recessed surface: the diff's number strip,
    /// the quick terminal, and the clipboard sheet. Marginally darker
    /// than `reviewAsideBackground` so the dividing line reads even
    /// without a stroked hairline.
    static let terminalColumnBackground: Color = .init(
        light: Color.white.opacity(0.30),
        dark: Color.black.opacity(0.28)
    )

    /// Fills for the one-line header above every pane. Washes
    /// laid over whatever the pane itself shows rather than solid tones: the
    /// terminal's background follows the user's theme and window opacity,
    /// and a fixed tone read as a dark band over the lighter terminals people
    /// actually run. A wash keeps the header the terminal's own color, a
    /// step toward the content. The focused pane's header takes one more
    /// step, so the pane taking keystrokes reads as raised without spending
    /// the accent on it.
    static let paneHeaderFill: Color = .init(
        light: Color.black.opacity(0.03),
        dark: Color.white.opacity(0.03)
    )
    static let paneHeaderFocusedFill: Color = .init(
        light: Color.black.opacity(0.06),
        dark: Color.white.opacity(0.07)
    )

    /// Hairline between a pane header and the terminal below it. Darker than
    /// both header washes rather than another light wash: drawn over the
    /// focused header's brighter fill, a light line of nearly the same
    /// strength vanished, and the focused pane lost its edge.
    static let paneHeaderDivider: Color = .init(
        light: Color.black.opacity(0.12),
        dark: Color.black.opacity(0.35)
    )

    /// Accent palette for projects (and the scratch tabs that kept a
    /// group's color). Indices are stable —
    /// never reorder, only append, so persisted `paletteIndex` values
    /// stay valid across upgrades. 16 entries laid out as 8×2 in the
    /// picker.
    static let projectPalette: [Color] = [
        Color(red: 0.231, green: 0.310, blue: 0.769), // 0  indigo
        Color(red: 0.000, green: 0.620, blue: 0.541), // 1  teal
        Color(red: 0.918, green: 0.345, blue: 0.310), // 2  coral
        Color(red: 0.957, green: 0.706, blue: 0.247), // 3  amber
        Color(red: 0.541, green: 0.482, blue: 0.776), // 4  lavender
        Color(red: 0.298, green: 0.667, blue: 0.345), // 5  moss
        Color(red: 0.890, green: 0.451, blue: 0.612), // 6  rose
        Color(red: 0.345, green: 0.522, blue: 0.749), // 7  slate-blue
        Color(red: 0.580, green: 0.380, blue: 0.220), // 8  bronze
        Color(red: 0.420, green: 0.420, blue: 0.470), // 9  graphite
        Color(red: 0.776, green: 0.157, blue: 0.235), // 10 crimson
        Color(red: 0.580, green: 0.604, blue: 0.235), // 11 olive
        Color(red: 0.337, green: 0.659, blue: 0.847), // 12 sky
        Color(red: 0.494, green: 0.808, blue: 0.659), // 13 mint
        Color(red: 0.808, green: 0.314, blue: 0.616), // 14 magenta
        Color(red: 0.961, green: 0.580, blue: 0.196) // 15 saffron
    ]
}

// MARK: - Environment

extension EnvironmentValues {
    /// The user-chosen accent resolved to a `Color`. The root scene
    /// injects this from `AppearanceSettings.accentColor`; any view
    /// painting an accent point reads `@Environment(\.weirAccent)`
    /// instead of reaching for `WeirColor.defaultAccent` so it
    /// tracks the picker live.
    @Entry var weirAccent: Color = WeirColor.defaultAccent
}

extension View {
    /// Re-apply Weir's accent + SwiftUI `tint` inside a sheet or
    /// popover. macOS presents these in a detached window, so the
    /// parent's `.tint(_:)` modifier and `\.weirAccent` environment
    /// don't reach the content automatically — every callsite has to
    /// thread the value through manually for Toggle / Button / etc.
    /// inside the sheet to track the user's picker.
    func weirAccentPropagated(_ accent: Color) -> some View {
        environment(\.weirAccent, accent).tint(accent)
    }
}

// MARK: - Light/Dark adaptive helper

private extension Color {
    /// Construct a Color that resolves to different values in light/dark mode.
    /// Routed through NSColor so it tracks macOS appearance changes.
    init(light: Color, dark: Color) {
        self = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.name == .darkAqua
                || appearance.name == .vibrantDark
                || appearance.name == .accessibilityHighContrastDarkAqua
                || appearance.name == .accessibilityHighContrastVibrantDark
            return isDark ? NSColor(dark) : NSColor(light)
        }))
    }
}
