// ContainerSymbol.swift
// Weir — the symbol each kind of container is drawn with, and a project's palette color.

import SwiftUI

/// SF Symbol per container kind, read by every surface that names a
/// container — the command palette catalog, which cannot reach a
/// `@MainActor` view type, among them — so each draws the same glyph.
/// The set divides containers by what they own: a repository, a branch.
enum ContainerSymbol {
    static let project = "book.closed"
    static let worktree = "arrow.triangle.branch"
}

/// Palette color for a project's (or a scratch tab's) paletteIndex: the
/// dot markers beside a project's name.
extension WeirColor {
    static func paletteColor(_ idx: Int?) -> Color {
        if let idx, projectPalette.indices.contains(idx) {
            return projectPalette[idx]
        }
        return defaultAccent
    }

    /// Each palette color's name, in `projectPalette`'s order, for the
    /// picker's tooltips and VoiceOver: a number says nothing of the color.
    static let projectPaletteNames: [LocalizedStringResource] = [
        LocalizedStringResource("Indigo", comment: "Project color name"),
        LocalizedStringResource("Teal", comment: "Project color name"),
        LocalizedStringResource("Coral", comment: "Project color name"),
        LocalizedStringResource("Amber", comment: "Project color name"),
        LocalizedStringResource("Lavender", comment: "Project color name"),
        LocalizedStringResource("Moss", comment: "Project color name"),
        LocalizedStringResource("Rose", comment: "Project color name"),
        LocalizedStringResource("Slate Blue", comment: "Project color name"),
        LocalizedStringResource("Bronze", comment: "Project color name"),
        LocalizedStringResource("Graphite", comment: "Project color name"),
        LocalizedStringResource("Crimson", comment: "Project color name"),
        LocalizedStringResource("Olive", comment: "Project color name"),
        LocalizedStringResource("Sky", comment: "Project color name"),
        LocalizedStringResource("Mint", comment: "Project color name"),
        LocalizedStringResource("Magenta", comment: "Project color name"),
        LocalizedStringResource("Saffron", comment: "Project color name")
    ]
}
