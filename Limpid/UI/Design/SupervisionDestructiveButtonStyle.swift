// SupervisionDestructiveButtonStyle.swift
// Limpid — the one look every destructive action of the supervision UI shares.

import SwiftUI

/// A button that rewrites the person's files: "Restore Code", "Restore
/// Code to Before This Turn…", and the review's hunk discard. One
/// look for all of them, so the person learns it once: the window's
/// bordered button with its title in the stop color,
/// filled on hover like every other bordered button. Not filled at rest,
/// so it never reads as the bar's primary button.
struct SupervisionDestructiveButtonStyle: ButtonStyle {
    /// `.compact` for a row of the changes panel, `.mini` for a review
    /// hunk's header.
    var size = SupervisionSecondaryButtonStyle.Size.regular

    func makeBody(configuration: Configuration) -> some View {
        SupervisionSecondaryButtonStyle(size: size, tone: .destructive)
            .makeBody(configuration: configuration)
    }
}
