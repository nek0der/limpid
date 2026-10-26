// LimpidTypography.swift
// Limpid — typography tokens: the type sizes every surface draws its words and symbols in.

import SwiftUI

/// Limpid typography.
///
/// **Guidelines**:
/// - UI uses SF Pro (system font).
/// - Monospace is for what the terminal and Git name: commands, terminal
///   lines, branch names and paths (`Font.supervisionCode`), and numbers
///   that stand in a column.
/// - Every size is a step of `LimpidFont.Supervision.Size`; no view writes
///   a point size of its own. The empty states (`SupervisionEmptyState`)
///   and the empty session area's hints (`EmptySessionHintRow`, with their
///   keycaps) alone scale their steps with Dynamic Type.
enum LimpidFont {

    // MARK: - UI

    /// Primary title (dialog titles, the clipboard confirmation).
    static let title: Font = .supervision(.display, weight: .semibold)

    /// Section headline (e.g. the review prompt preview's title).
    static let headline: Font = .supervision(.label, weight: .medium)

    /// Body — primary text in a sheet or a panel.
    static let body: Font = .supervision(.label, weight: .medium)

    /// Secondary body — supporting text such as hover tooltips.
    static let bodySecondary: Font = .supervision(.row)

    /// Caption — the smallest words of a line, such as a banner's.
    static let caption: Font = .supervision(.caption)

}

extension LimpidFont {
    /// The supervision window's type.
    enum Supervision {
        /// What a branch name or a path takes of the words around it: 92%,
        /// a little under them. Monospaced figures run wide, so at the full
        /// size a name such as "main" would read larger than the project name
        /// beside it.
        static let codeScale: CGFloat = 0.92

        /// A surface's heading: the sidebar's "Projects" and the changes
        /// panel's "Changes", in one face so the two read as the same kind
        /// of title. The session header's name is two steps larger
        /// (`LimpidLayout.Supervision.sessionHeaderNameFontSize`).
        static let surfaceHeading: Font = .supervision(
            LimpidLayout.Supervision.surfaceHeadingFontSize,
            weight: .semibold
        )
    }
}

extension LimpidFont.Supervision {
    /// The steps of the window's type, a fixed set of sizes so no surface
    /// sets a size of its own, each named for what it mostly draws.
    /// Symbols take the same steps as words, so an icon beside a line is
    /// sized with the line.
    enum Size: CGFloat, CaseIterable, Sendable {
        /// A list's bullet dot.
        case bullet = 5
        /// The least chevron, beside a menu field's name.
        case marker = 7
        /// Chevrons and disclosure triangles.
        case disclosure = 8
        /// A symbol inside a caption line: an ✕, a check, a count's mark.
        case glyph = 9
        /// An agent's badge letters, a keycap.
        case badge = 9.5
        /// The least words, and the symbols of a find bar or a field.
        case micro = 10
        /// A half step under a caption: a terminal's last lines, a note.
        case detail = 10.5
        /// A caption: the second line of a row, a banner's words.
        case caption = 11
        /// A row's facts and times.
        case meta = 11.5
        /// A list row's name, a sheet's label.
        case row = 12
        /// Body words of a field or a menu item.
        case body = 12.5
        /// A heading's words, a card's title, a button's.
        case label = 13
        /// A symbol in a title bar control or a heading line.
        case icon = 14
        /// The session header's name, two steps above a surface's heading.
        case heading = 15
        /// A sheet's and a popover's title.
        case title = 16
        /// A dialog's title, the rails' symbols, a drop target's.
        case display = 18
        /// A pane's drop target.
        case symbolLarge = 22
        /// An alert's leading symbol.
        case symbolHero = 28
    }
}

extension Font {
    /// The system face at a step of the supervision window's type
    /// (`LimpidFont.Supervision.Size`).
    static func supervision(
        _ size: LimpidFont.Supervision.Size,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: size.rawValue, weight: weight, design: design)
    }

    /// A branch name or a path among words of `size`: monospaced, at
    /// `LimpidFont.Supervision.codeScale` of them, wherever it is drawn.
    static func supervisionCode(beside size: LimpidFont.Supervision.Size, weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue * LimpidFont.Supervision.codeScale, weight: weight, design: .monospaced)
    }
}
