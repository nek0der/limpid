// LimpidColors.swift
// Limpid — semantic color tokens; maps design-rules.md §5 into
// SwiftUI `Color` values used across the app.

import SwiftUI

/// Semantic colors for Limpid. Maps design-rules.md §5 into SwiftUI Color.
///
/// **Guidelines**:
/// - Accent colors look muted alone but pop through glass.
/// - Status colors go through system semantics so they follow dark/light.
/// - Only one accent color per screen (the "5% rule", §5.3).
enum LimpidColor {
    /// Resolves to the macOS System Accent the user has picked in
    /// System Settings → Appearance. Painted whenever Limpid's own
    /// accent picker is on `AccentColor.default`, so a user who never
    /// opens our Settings still sees Limpid follow their OS-wide
    /// choice (Blue, Multicolor, Graphite, …). Callers should reach
    /// for `accent(for:)` instead so they honor the user's Limpid
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

    /// Success / completion / running.
    static let success: Color = .green

    /// Warning / waiting.
    static let warning: Color = .yellow

    /// Error / failure.
    static let error: Color = .red

    /// Primary text.
    static let primaryText: Color = .primary

    /// Secondary text (60% opacity).
    static let secondaryText: Color = .secondary

    /// Tertiary text (e.g. empty-state captions).
    static let tertiaryText: Color = .primary.opacity(0.5)

    /// Subtle panel divider — used as a soft shadow substitute, not stroked as a line.
    static let panelDivider: Color = .primary.opacity(0.06)

    /// Row-state fills shared by the sidebar pills and the tab bar pills.
    /// Picking once here keeps the two strips visually in lockstep.
    /// Active fill is intentionally subtle in dark mode — the rounded
    /// stroke on top of it carries most of the "selected" signal.
    static let rowActiveFill: Color = .primary.opacity(0.08)
    static let rowHoverFill: Color = .primary.opacity(0.04)
    /// Subdued fill used on a parent row when one of its descendants
    /// owns selection (e.g. a project header whose worktree is the
    /// active container). Lighter than `rowActiveFill` and paired with
    /// no stroke so the descendant's pill remains the dominant cue.
    static let rowAncestorActiveFill: Color = .primary.opacity(0.03)
    static let tabActiveFill: Color = .primary.opacity(0.10)
    /// Stroke color applied to the *active* sidebar group pill so the
    /// selection stands out without leaning on the accent palette. Used
    /// by `SelectablePillBackground` and the Command Palette field
    /// outline (`ToolbarPaletteField`). Adaptive so the stroke reads
    /// against the near-white light-mode `.glassEffect` background as
    /// well as the dark-mode slab.
    static let rowActiveBorder: Color = .init(
        light: Color.black.opacity(0.18),
        dark: Color.white.opacity(0.28)
    )
    /// Hairline used around the sidebar card and the floating glass capsule.
    static let toolbarHairline: Color = .primary.opacity(0.08)

    /// Color used for the notification bell across tab column / container column / toolbar.
    /// Orange reads clearly on the dark slab and matches the warmth
    /// of a "needs attention" cue without the urgency of red.
    static let notificationBell: Color = .orange

    /// Dirty-worktree dot in the sidebar's Worktree row.
    static let gitDirtyDot: Color = .orange

    /// Ahead/behind indicators next to a Worktree label. Kept subdued
    /// since they appear on every git-backed row.
    static let gitAheadBehindText: Color = .primary.opacity(0.55)

    /// Background tint for the tab column (tab list). Slightly lighter
    /// than the toolbar / window root so the column reads as a distinct
    /// surface without using a hairline.
    static let tabColumnBackground: Color = .init(
        light: Color.white.opacity(0.45),
        dark: Color.black.opacity(0.18)
    )

    /// Background tint for the terminal column detail pane. Marginally darker than
    /// tab column so the dividing line reads even without a stroked hairline.
    static let terminalColumnBackground: Color = .init(
        light: Color.white.opacity(0.30),
        dark: Color.black.opacity(0.28)
    )

    /// Vertical hairline between the tab and terminal columns in the default
    /// (translucent) appearance. Visible only in light mode — in dark
    /// mode the two column tints already separate the columns, so the
    /// line stays clear to avoid a hard rule over the glass.
    static let tabColumnTrailingDivider: Color = .init(
        light: Color.black.opacity(0.08),
        dark: Color.clear
    )

    /// Vertical hairline used in reduce-transparency mode, where tab column and
    /// terminal column share one opaque tone and so need an explicit boundary in both
    /// appearances.
    static let tabColumnTrailingDividerOpaque: Color = .init(
        light: Color.black.opacity(0.08),
        dark: Color.white.opacity(0.10)
    )

    /// Rim highlight along the top of glass panels (§2.2).
    static let rimLight: Color = .init(
        light: Color.white.opacity(0.15),
        dark: Color.white.opacity(0.08)
    )

    /// Accent palette for groups / projects. Indices are stable —
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
    /// painting an accent point reads `@Environment(\.limpidAccent)`
    /// instead of reaching for `LimpidColor.defaultAccent` so it
    /// tracks the picker live.
    @Entry var limpidAccent: Color = LimpidColor.defaultAccent
}

extension View {
    /// Re-apply Limpid's accent + SwiftUI `tint` inside a sheet or
    /// popover. macOS presents these in a detached window, so the
    /// parent's `.tint(_:)` modifier and `\.limpidAccent` environment
    /// don't reach the content automatically — every callsite has to
    /// thread the value through manually for Toggle / Button / etc.
    /// inside the sheet to track the user's picker.
    func limpidAccentPropagated(_ accent: Color) -> some View {
        environment(\.limpidAccent, accent).tint(accent)
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
