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
    /// Accent (light: deep indigo, dark: mint green).
    static let accent: Color = .init(
        light: Color(red: 0.231, green: 0.310, blue: 0.769), // #3B4FC4
        dark: Color(red: 0.373, green: 0.890, blue: 0.788) // #5FE3C9
    )

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
    /// Stroke colour applied to the *active* sidebar group pill so the
    /// selection stands out without leaning on the accent palette.
    static let rowActiveBorder: Color = .white.opacity(0.28)
    /// Hairline used around the sidebar card and the floating glass capsule.
    static let chromeHairline: Color = .primary.opacity(0.08)

    /// Color used for the notification bell across L2 / L1 / chrome.
    /// Orange reads clearly on the dark slab and matches the warmth
    /// of a "needs attention" cue without the urgency of red.
    static let notificationBell: Color = .orange

    /// Dirty-worktree dot in the sidebar's Worktree row.
    static let gitDirtyDot: Color = .orange

    /// Ahead/behind indicators next to a Worktree label. Kept subdued
    /// since they appear on every git-backed row.
    static let gitAheadBehindText: Color = .primary.opacity(0.55)

    /// Background tint for the L2 column (tab list). Slightly lighter
    /// than the chrome / window root so the column reads as a distinct
    /// surface without using a hairline.
    static let l2Background: Color = .init(
        light: Color.white.opacity(0.45),
        dark: Color.black.opacity(0.18)
    )

    /// Background tint for the L3 detail pane. Marginally darker than
    /// L2 so the dividing line reads even without a stroked hairline.
    static let l3Background: Color = .init(
        light: Color.white.opacity(0.30),
        dark: Color.black.opacity(0.28)
    )

    /// Vertical hairline between the L2 and L3 columns in the default
    /// (translucent) appearance. Visible only in light mode — in dark
    /// mode the two column tints already separate the columns, so the
    /// line stays clear to avoid a hard rule over the glass.
    static let l2TrailingDivider: Color = .init(
        light: Color.black.opacity(0.08),
        dark: Color.clear
    )

    /// Vertical hairline used in reduce-transparency mode, where L2 and
    /// L3 share one opaque tone and so need an explicit boundary in both
    /// appearances.
    static let l2TrailingDividerOpaque: Color = .init(
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
