// PRMarkPresentation.swift
// Weir — visual treatment for a session's pull-request mark.
//
// Sibling of `AgentStatePresentation`: both resolve one piece of row
// state into the drawing that stands for it, and keep that mapping out
// of the view.
//
// The mark is attached on the right of a session, beside its agent
// badge (`SessionPRMark`), and never stands in its state glyph's place:
// the left says the state, the right what is attached. Whether it is
// drawn is the row's (`SessionRowFact.pullRequest`); this type only
// answers what it looks like.
//
// Two channels carry the state:
//
//   - kind  → the request's own state, told apart by its drawing alone
//   - badge → its checks: a failing one in red, a running one as an
//             amber dot, and a passing one as a thin green check
//
// A running check is something to wait on, so it earns a dot of the
// waiting color. A passing one is drawn lighter than either disc, a line
// with no disc, so that failing and running checks still stand out on a
// sidebar where most requests pass.
//
// The drawings are `SessionPRMark`'s own line marks rather than the
// filled Octicons: a filled shape cannot be dashed, and the draft is the
// open mark dashed.

import SwiftUI

/// Resolved visual treatment for a row's pull-request mark. Absent
/// when the row has no request, in which case the row draws no mark
/// and holds no slot for one.
struct PRMarkPresentation {
    /// The request's state as the mark draws it (`PRLineGlyph`).
    enum Kind: Equatable {
        case open
        case draft
        case merged
        case closed
    }

    let kind: Kind
    let tint: Color
    /// Corner badge for the request's checks, or nil when it has none.
    let badge: Badge?
    /// Localized text handed to `.accessibilityLabel(Text(_:))`.
    /// `LocalizedStringResource` rather than `LocalizedStringKey` so
    /// the type stays implicitly `Sendable`.
    let accessibilityKey: LocalizedStringResource

    /// The checks' outcome as the badge draws it (`SessionPRMark`).
    enum BadgeKind: Equatable {
        /// A red disc with a ✕.
        case failing
        /// An amber dot with no glyph.
        case running
        /// A thin green check with no disc.
        case passing
    }

    struct Badge {
        let kind: BadgeKind
        let color: Color
        /// Spoken after the state, because the badge carries meaning
        /// the state label does not.
        let accessibilityKey: LocalizedStringResource

        /// The badge for a request's checks, or nil when it has none.
        /// Each outcome has its own speech: without it, the three would
        /// reach a VoiceOver user through color and shape alone.
        static func supervisionStyle(for checks: PRChecks?) -> Badge? {
            switch checks?.conclusion {
            case nil:
                nil
            case .failure:
                // The stopped glyph's red, since both are failures.
                Badge(kind: .failing, color: SupervisionTokens.stopped.color, accessibilityKey: "Checks failing")
            case .pending:
                // The waiting color: a running check is something to wait on.
                Badge(kind: .running, color: SupervisionTokens.waiting.color, accessibilityKey: "Checks running")
            case .success:
                // A check's result rather than a state, so a pass may
                // be green, in the hover card's green for the same result.
                Badge(kind: .passing, color: SupervisionTokens.added.color, accessibilityKey: "Checks passed")
            }
        }
    }

    /// The mark in the supervision UI: every state in `muted`, told
    /// apart by its shape alone, and its checks on the corner. We
    /// add no color for the request itself; only its checks are colored.
    static func supervisionStyle(for info: PRInfo?) -> PRMarkPresentation? {
        guard let info else { return nil }
        let badge = Badge.supervisionStyle(for: info.checks)
        let tint = SupervisionTokens.muted.color
        switch info.state {
        case .open:
            // Draft only modulates the open state. A request that has
            // been closed or merged is finished whether or not it was
            // ever a draft, and the forges present it that way too, so
            // the flag must not mask a terminal state.
            return info.isDraft
                ? PRMarkPresentation(kind: .draft, tint: tint, badge: badge, accessibilityKey: "PR draft")
                : PRMarkPresentation(kind: .open, tint: tint, badge: badge, accessibilityKey: "PR open")
        case .merged:
            return PRMarkPresentation(kind: .merged, tint: tint, badge: badge, accessibilityKey: "PR merged")
        case .closed:
            return PRMarkPresentation(kind: .closed, tint: tint, badge: badge, accessibilityKey: "PR closed")
        }
    }
}
