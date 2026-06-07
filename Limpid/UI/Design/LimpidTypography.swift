// LimpidTypography.swift
// Limpid — typography tokens; maps design-rules.md §4 into reusable
// SwiftUI font / weight constants.

import SwiftUI

/// Limpid typography hierarchy. Maps design-rules.md §4 into code.
///
/// **Guidelines**:
/// - UI uses SF Pro (system font).
/// - Monospace (terminal / commands / numerics) is fixed-width with tabular figures.
/// - At most two hierarchy levels; the primary weight is `.medium`.
enum LimpidFont {

    // MARK: - UI

    /// Primary title (settings sections, dialog titles, etc.).
    static let title: Font = .system(size: 18, weight: .semibold, design: .default)

    /// Section headline (e.g. sidebar group headers).
    static let headline: Font = .system(size: 13, weight: .medium, design: .default)

    /// Body — primary text such as sidebar tab names.
    static let body: Font = .system(size: 13, weight: .medium, design: .default)

    /// Secondary body — supporting text such as hover tooltips.
    static let bodySecondary: Font = .system(size: 12, weight: .regular, design: .default)

    /// Caption — smallest elements like the status bar and Blocks summary.
    static let caption: Font = .system(size: 11, weight: .regular, design: .default)

    /// Primary command-palette item.
    static let paletteItem: Font = .system(size: 14, weight: .medium, design: .default)

    // MARK: - Monospace

    /// Default terminal font (user-overridable).
    static let terminal: Font = .system(size: 13, design: .monospaced)

    /// Blocks command name (monospaced, lighter weight).
    static let blockCommand: Font = .system(size: 12, weight: .medium, design: .monospaced)

    /// Main-pane header (path / branch display).
    static let paneHeader: Font = .system(size: 12, weight: .regular, design: .monospaced)
}

// MARK: - Text modifiers

extension Text {
    /// For numeric / aligned values (cost, line counts, port numbers, etc.).
    /// design-rules §4.3 — always apply tabular figures.
    func limpidTabular() -> some View {
        self.monospacedDigit()
    }
}
