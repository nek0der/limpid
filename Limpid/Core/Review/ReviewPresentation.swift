// ReviewPresentation.swift
// Limpid — how the review surface is laid out in a window, and how wide its
// file list is.
//
// In Core, not beside the views it describes: the command palette, the
// shortcut table and `ReviewAgents` all ask this type whether review is up and
// what it is drawn with, and Core cannot reach into UI. The measurements come
// with it because the state depends on them — a rail width means nothing
// without the range it is clamped to.

import CoreGraphics
import Foundation
import Observation

/// How wide the file list is.
///
/// A range rather than one number: paths in a repository of any depth do not
/// fit a fixed rail, and which end of the name survives truncation is not
/// something a default can decide for every repository.
enum ReviewRail {
    static let minimum: CGFloat = 170
    static let maximum: CGFloat = 460
    /// The width the file list opens at, and returns to on a double click
    /// of its divider: the review tab's rows carry a checkbox before the
    /// name.
    static let `default`: CGFloat = 240
    /// What the diff needs to stay readable beside the list: two columns of
    /// code and the gutter between them.
    static let diffMinimum: CGFloat = 360
    /// Smallest surface that can keep both the file list and readable diff
    /// inline. Window layout uses the same boundary before reserving space for
    /// navigation, so one panel does not force the other into an overlay.
    static var inlineMinimumWidth: CGFloat {
        minimum + diffMinimum
    }

    /// How wide the list may be in a surface this wide, or `nil` when it has
    /// to go away entirely.
    ///
    /// The list carries the layout switch, the filter and the read marks, so
    /// losing it costs the reader something — but a fixed width plus a diff
    /// that cannot shrink is a surface wider than the window, and on a
    /// half-screen tile the code ran off the edge with no way to bring it back.
    static func width(_ requested: CGFloat, in available: CGFloat) -> CGFloat? {
        guard isInline(in: available) else { return nil }
        return min(max(requested, minimum), maximumWidth(in: available))
    }

    /// Whether the list can stay beside the diff at all. Asked on its own,
    /// rather than as `width(_:in:) != nil`, by the views that only need to
    /// know where the list is: naming the requested width there made them
    /// read it, and rebuild with it on every frame of a divider drag.
    static func isInline(in available: CGFloat) -> Bool {
        available >= inlineMinimumWidth
    }

    /// The widest the list may be in a surface this wide: what the diff's
    /// floor leaves, in whole points. The one bound both the divider's drag
    /// and the drawn width clamp to. They kept a copy each, and neither
    /// counted the divider between the list and the diff, so at the cap the
    /// two columns came to a point wider than the surface — and the review's
    /// chrome above them, centered on that wider row, moved under the
    /// pointer as the divider reached it.
    static func maximumWidth(in available: CGFloat) -> CGFloat {
        max(minimum, min(maximum, (available - diffMinimum).rounded(.down)))
    }

    /// A dragged width, clamped and rounded to whole points: a drag reports
    /// fractional deltas, and a list a fraction of a point wider moved the
    /// diff's text and every control right of it by that fraction on each
    /// frame.
    static func resized(to proposed: CGFloat, in available: CGFloat) -> CGFloat {
        min(max(proposed.rounded(), minimum), maximumWidth(in: available))
    }
}

/// App-owned review presentation. Keeping this outside `WorkspaceSession`
/// avoids persisting a temporary inspection mode into session restoration.
@MainActor
@Observable
final class ReviewPresentation {
    /// The repository shown while the terminal area shows review.
    var directory: URL?

    /// The destination for the assembled feedback — which is why review never
    /// needs to ask which agent to write to. The pane the review was opened
    /// from, until the reader picks another.
    private(set) var originPaneID: UUID?

    /// Which layout the diff is read in. Window-scoped: it is how the reader
    /// wants to read, not something the worktree being read owns — and the
    /// surface is rebuilt from scratch every time review opens. A review
    /// opened next starts from it. The supervision window's review tab, which
    /// a project keeps while its window shows another, takes its layout with
    /// it, and the window reads the tab in it again when the tab comes back
    /// (`ParkedReview.Tab`).
    var diffLayout: ReviewDiffLayout = .unified

    /// Window-scoped like `diffLayout`, and stored beside it rather than
    /// inside a struct with it: observation tracks whole stored properties,
    /// and a view that only asks how the diff is laid out should not be
    /// rebuilt on every frame of a divider drag. Kept with a review tab its
    /// project keeps, as `diffLayout` is.
    var railWidth: CGFloat = ReviewRail.default

    /// Which opening of the surface this is, and `nil` while it is down.
    ///
    /// An insert runs Git before it delivers, and the reader can close review
    /// and open it again inside that wait. "Still on screen, and still the same
    /// pane" was true again by then, so an insert started in the review they
    /// had closed pasted into the one they had just opened and then closed
    /// that. Compared rather than counted.
    ///
    /// Changes only where `directory` does, and means the same thing — nil
    /// exactly while there is no directory.
    private(set) var opening: UUID?

    /// Scope requested by the action that opened Review, or by a later jump
    /// into the same repository. The generation lets an identical scope be
    /// requested twice after the reader has switched away from it manually.
    private(set) var requestedScope: ReviewScope?
    private(set) var scopeRequestID = UUID()

    var isPresented: Bool {
        directory != nil
    }

    /// The one symbol every Review Changes affordance is drawn with — the
    /// View menu, the shortcut list, the command palette, and the review's
    /// own tab in the pane strip. They carried two between them, so the
    /// same command read as two; Quick Open has a mark of its own. `nonisolated` because
    /// the shortcut table names its icon from off the main actor.
    nonisolated static let symbol = "doc.text.magnifyingglass"

    func open(
        _ directory: URL,
        originPaneID: UUID?,
        initialScope: ReviewScope? = nil
    ) {
        let normalized = directory.resolvingSymlinksInPath()
        if self.directory?.resolvingSymlinksInPath() == normalized, let initialScope {
            self.originPaneID = originPaneID
            requestedScope = initialScope
            scopeRequestID = UUID()
            return
        }
        self.originPaneID = originPaneID
        requestedScope = initialScope
        scopeRequestID = UUID()
        self.directory = normalized
        opening = UUID()
    }

    func close() {
        directory = nil
        originPaneID = nil
        requestedScope = nil
        opening = nil
    }

    /// The destination the reader named.
    func pinDestination(to paneID: UUID) {
        originPaneID = paneID
    }

    /// The file list's divider moved. Guarded rather than assigned:
    /// Observation's generated setter notifies on every write, same value or
    /// not, so a drag frame that wrote the width it already had would still
    /// invalidate every view reading it.
    func resizeRail(to proposed: CGFloat, in available: CGFloat) {
        let next = ReviewRail.resized(to: proposed, in: available)
        if railWidth != next {
            railWidth = next
        }
    }
}
