// PRMarkPresentation.swift
// Limpid — visual treatment for a sidebar row's pull-request mark.
//
// Sibling of `AgentStatePresentation` and `ContainerPresentation`:
// each resolves one piece of row state into the drawing that stands
// for it, and keeps that mapping out of the view.
//
// The mark belongs in the row's trailing group, not on the leading
// marker: a Project row's leading marker is the palette dot the user
// picked, so tinting it for a request would make one colour mean two
// things, and a worktree row has no leading marker at all.
//
// Whether the mark is drawn at rest is settled elsewhere, by
// `PRInfo.needsAttention` and the Settings toggle beside it. This
// type only answers what it looks like once something asked for one.
//
// The glyphs are bundled Octicons rather than SF Symbols, because a
// shape that reads as a pull request has to be a line drawing and SF
// Symbols only offers weights — at every weight it sat thinner than
// the filled circle `AgentStatePresentation` puts beside it. Octicons
// are filled paths, so scale changes what they occupy, not how solid
// they are. They also give all four states their own outline, which
// is what keeps the state readable for a viewer who cannot separate
// the hues.
//
// Two channels carry the state:
//
//   - glyph + tint → the request's own state
//   - badge        → a failing check, which outranks that state
//
// Asset names match Octicons' own file names so the source is
// findable without a lookup table; license sits in
// `THIRD-PARTY-NOTICES`.
//
// The accent arrives as a parameter because `Color.accentColor` is
// the OS System Accent, not Limpid's — every other accent point reads
// `\.limpidAccent` so it tracks the Appearance picker live.

import SwiftUI

/// Resolved visual treatment for a row's pull-request mark. Absent
/// when the row has no request, in which case the row draws no mark
/// and holds no slot for one.
struct PRMarkPresentation {
    /// Asset-catalog name, not an SF Symbol — see the note above.
    let glyph: String
    let tint: Color
    /// Corner badge, or nil when the glyph and tint say everything.
    let badge: Badge?
    /// Localized text handed to `.accessibilityLabel(Text(_:))`.
    /// `LocalizedStringResource` rather than `LocalizedStringKey` so
    /// the type stays implicitly `Sendable`.
    let accessibilityKey: LocalizedStringResource

    struct Badge {
        /// Asset-catalog name, like `PRMarkPresentation.glyph`.
        let glyph: String
        let color: Color
        /// Spoken after the state, because the badge carries meaning
        /// the state label does not.
        let accessibilityKey: LocalizedStringResource
    }

    static func style(for info: PRInfo?, accent: Color) -> PRMarkPresentation? {
        guard let info else { return nil }
        // Resolved once: the badge does not vary with `info.state`,
        // only with the checks. Without its own speech a failing check
        // would reach a VoiceOver user through colour alone.
        let badge: Badge? = info.checks?.conclusion == .failure ? Badge(
            // From the same drawings as the glyphs it sits on. This
            // used to be `xmark.octagon.fill`, chosen so the badge
            // would not repeat the circle `AgentState.error` draws —
            // but at badge size an octagon is a circle, so the
            // distinction was never delivered. What separates the two
            // in practice is size and position: this rides the corner
            // of another glyph at well under half its width.
            glyph: "x-circle-fill",
            color: LimpidColor.error,
            accessibilityKey: "Checks failing"
        ) : nil

        switch info.state {
        case .open:
            // Draft only modulates the open state. A request that has
            // been closed or merged is finished whether or not it was
            // ever a draft, and the forges present it that way too, so
            // the flag must not mask a terminal state.
            guard info.isDraft else {
                return PRMarkPresentation(
                    glyph: "git-pull-request",
                    tint: accent,
                    badge: badge,
                    accessibilityKey: "PR open"
                )
            }
            return PRMarkPresentation(
                glyph: "git-pull-request-draft",
                // The open glyph draws the branch merging in as a
                // solid line and arrowhead; the draft replaces that
                // with two loose dots — the same object, on a path not
                // yet joined up. A shape difference, so it survives
                // without colour.
                tint: LimpidColor.secondaryText,
                badge: badge,
                accessibilityKey: "PR draft"
            )
        case .merged:
            return PRMarkPresentation(
                glyph: "git-merge",
                tint: LimpidColor.merged,
                badge: badge,
                accessibilityKey: "PR merged"
            )
        case .closed:
            // Closed without merging sits below every other state: the
            // row had a request and no longer has a live one, so it
            // should recede rather than compete.
            return PRMarkPresentation(
                glyph: "git-pull-request-closed",
                tint: LimpidColor.tertiaryText,
                badge: badge,
                accessibilityKey: "PR closed"
            )
        }
    }
}
