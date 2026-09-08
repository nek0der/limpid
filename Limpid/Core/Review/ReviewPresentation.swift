// ReviewPresentation.swift
// Limpid — how the review surface is laid out in a window, and how wide and
// tall its parts are.
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
    static let `default`: CGFloat = 232
    /// What the diff needs to stay readable beside the list: two columns of
    /// code and the gutter between them.
    static let diffMinimum: CGFloat = 360

    /// How wide the list may be in a surface this wide, or `nil` when it has
    /// to go away entirely.
    ///
    /// The list carries the layout switch, the filter and the read marks, so
    /// losing it costs the reader something — but a fixed width plus a diff
    /// that cannot shrink is a surface wider than the window, and on a
    /// half-screen tile the code ran off the edge with no way to bring it back.
    static func width(_ requested: CGFloat, in available: CGFloat) -> CGFloat? {
        guard available - diffMinimum >= minimum else { return nil }
        return min(requested, available - diffMinimum)
    }
}

/// How tall the terminal docked under review is, and whether it is there at
/// all.
///
/// This was three fixed stops on a shortcut. A terminal's useful height
/// depends on what the agent is printing, so the divider is draggable and the
/// stops are gone; the shortcut now toggles the pane away and back.
enum ReviewStrip {
    static let minimum: CGFloat = 90
    static let `default`: CGFloat = 240
    /// The most of the surface the terminal may take. Review is what the
    /// reader opened; a strip that could swallow it would leave them resizing
    /// their way back to the diff.
    static let maximumFraction: CGFloat = 0.8

    /// `nil` renders no pane at all rather than a zero-height one, so
    /// libghostty is never handed a new size and the agent's tty keeps its
    /// geometry while the pane is away.
    static func height(_ height: CGFloat, isCollapsed: Bool, in available: CGFloat) -> CGFloat? {
        guard !isCollapsed, available > minimum else { return nil }
        return min(max(height, minimum), (available * maximumFraction).rounded(.down))
    }

    /// Rounded to whole points. A drag reports fractional deltas, and handing
    /// the terminal a new size for a change it cannot render is what a flicker
    /// is made of.
    static func resized(to proposed: CGFloat, in available: CGFloat) -> CGFloat {
        let limit = max((available * maximumFraction).rounded(.down), minimum)
        return min(max(proposed.rounded(), minimum), limit)
    }
}

/// App-owned review presentation. Keeping this outside `WindowSession`
/// avoids persisting a temporary inspection mode into session restoration.
@MainActor
@Observable
final class ReviewPresentation {
    /// The selected project or worktree while the terminal area shows review.
    var directory: URL?

    /// The pane docked below the review surface, and the destination for the
    /// assembled feedback — which is why review never needs to ask which agent
    /// to write to. It follows the focused pane by default: the strip is the
    /// one terminal on screen while review is up, so a destination that stayed
    /// behind after the user switched tab would be writing into something they
    /// cannot see — unless they pinned it, in which case the strip goes on
    /// rendering that pane whatever tab is active, and it stays visible.
    private(set) var originPaneID: UUID?

    /// Whether the reader named the destination themselves.
    ///
    /// Following the focus is right for the common shape — one agent, one
    /// pane, and the terminal under the diff is the one that wrote it. It is
    /// wrong for the shape this app exists for: several agents in one
    /// worktree, each in its own tab. There, reading the diff of one and
    /// glancing at another moved the destination onto the agent that had
    /// nothing to do with the comments, and the only thing that said so was a
    /// chip the reader had no reason to look at again.
    ///
    /// So an explicit choice sticks until the reader takes it back, and a new
    /// opening starts out following again — a pin is about this reading of
    /// this worktree, not a preference.
    private(set) var isDestinationPinned = false

    /// Two stored properties rather than one struct on purpose. Observation
    /// tracks whole stored properties, so a view that only asks whether the
    /// terminal is showing would be invalidated on every frame of a resize
    /// drag if the height traveled with it — which is what the review
    /// surface was doing while the divider moved.
    var isStripCollapsed = false
    var stripHeight: CGFloat = ReviewStrip.default

    /// Which layout the diff is read in. Window-scoped like the strip height,
    /// and for the same reason: it is how the reader wants to read, not
    /// something the worktree being read owns — and the surface is rebuilt
    /// from scratch every time review retargets.
    var diffLayout: ReviewDiffLayout = .unified

    /// Window-scoped like the strip's height, and stored beside it rather than
    /// inside a struct with it for the same reason: observation tracks whole
    /// stored properties, and a view that only asks how the diff is laid out
    /// should not be rebuilt on every frame of a divider drag.
    var railWidth: CGFloat = ReviewRail.default

    /// Set only after inserting feedback so closing review restores that pane.
    var insertedPaneID: UUID?

    /// Which opening of the surface this is, and `nil` while it is down.
    ///
    /// An insert runs Git before it delivers, and the reader can close review
    /// and open it again inside that wait. "Still on screen, and still the same
    /// pane" was true again by then, so an insert started in the review they
    /// had closed pasted into the one they had just opened and then closed
    /// that. Compared rather than counted, and left alone by `retarget`: the
    /// same opening looking at another worktree is still the opening the
    /// reader pressed Insert in.
    ///
    /// Changes only where `directory` does, and means the same thing — nil
    /// exactly while there is no directory.
    private(set) var opening: UUID?

    var isPresented: Bool {
        directory != nil
    }

    /// The one symbol every Review Changes affordance is drawn with — toolbar,
    /// View menu, container actions and command palette. They carried two
    /// between them, so the same command read as two. `nonisolated` because
    /// the shortcut table names its icon from off the main actor.
    nonisolated static let symbol = "doc.text.magnifyingglass"

    func open(_ directory: URL, originPaneID: UUID?) {
        insertedPaneID = nil
        self.originPaneID = originPaneID
        isDestinationPinned = false
        isStripCollapsed = false
        self.directory = directory
        opening = UUID()
    }

    func close() {
        directory = nil
        originPaneID = nil
        isDestinationPinned = false
        opening = nil
    }

    /// The destination the reader named. Pinned by the act of naming it:
    /// having gone to the trouble of picking a terminal, they do not mean it
    /// to be taken back by the next tab they look at.
    func pinDestination(to paneID: UUID) {
        originPaneID = paneID
        isDestinationPinned = true
    }

    /// Hand the destination back to whatever is focused, starting with the
    /// pane given — the focus moved while the pin held it, so releasing it
    /// without catching up would leave the strip on the pinned pane until the
    /// reader happened to move focus again.
    func followFocus(_ paneID: UUID?) {
        isDestinationPinned = false
        if let paneID {
            originPaneID = paneID
        }
    }

    /// The focus moved. Ignored while the destination is pinned, which is the
    /// whole of what a pin does.
    func focusedPaneChanged(to paneID: UUID?) {
        guard !isDestinationPinned else { return }
        originPaneID = paneID
    }

    /// The entry point is one control, so it has to close what it opened.
    /// Re-opening on a different directory rather than closing keeps the
    /// button meaningful after the user switches container while review is up.
    func toggle(_ directory: URL, originPaneID: UUID?) {
        if self.directory == directory {
            close()
        } else {
            open(directory, originPaneID: originPaneID)
        }
    }

    /// Follow the user to another project or worktree. Distinct from `open`
    /// because the strip height they chose is theirs, not part of the target.
    ///
    /// The pin does not survive it. A pin names one terminal, and the pane
    /// that was pinned belongs to the container being left — kept, it would
    /// hold the destination on a tab that is no longer on screen while the
    /// diff beside it described somewhere else entirely.
    func retarget(_ directory: URL, originPaneID: UUID?) {
        guard isPresented else { return }
        insertedPaneID = nil
        self.originPaneID = originPaneID
        isDestinationPinned = false
        self.directory = directory
    }

    func toggleStrip() {
        isStripCollapsed.toggle()
    }

    /// The height to render the docked terminal at, or `nil` for none.
    func stripHeight(in available: CGFloat) -> CGFloat? {
        ReviewStrip.height(stripHeight, isCollapsed: isStripCollapsed, in: available)
    }

    /// Guarded rather than assigned. Observation's generated setter notifies on
    /// every write, same value or not, so a drag frame that wrote
    /// `isStripCollapsed = false` over `false` invalidated every view watching
    /// it — which is the path splitting the height out of a struct was meant to
    /// close.
    func resizeStrip(to proposed: CGFloat, in available: CGFloat) {
        if isStripCollapsed {
            isStripCollapsed = false
        }
        let next = ReviewStrip.resized(to: proposed, in: available)
        if stripHeight != next {
            stripHeight = next
        }
    }
}
