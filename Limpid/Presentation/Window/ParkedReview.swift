// ParkedReview.swift
// Limpid — a review tab kept for its project while no window shows it, and the review state the windows share or carry with a tab.

import Foundation
import Observation

/// What became of the hunks discarded in the reviews of every window,
/// and the paths later turns changed that a discard is checked against.
/// One store for the app (`WindowRegistry.reviewDiscards`), keyed by the
/// worktree and the hunk (`ReviewHunkDiscardActions.key`, which spells the
/// worktree one way however a record spelled it): a worktree's records are
/// the worktree's, not a window's or a review's owner's, so every review of
/// it reads and writes the same ones wherever it is drawn or kept, and a
/// discard or an undo still running writes its end by its key, never into a
/// box that went stale meanwhile.
@MainActor
@Observable
final class ReviewDiscardRecords {
    /// The record of each hunk discarded, by the hunk.
    var hunkDiscards: [ReviewHunkKey: ReviewHunkDiscardRecord] = [:]
    /// The paths changed after a review range, by its worktree, its end
    /// tree, and the end tree of the latest turn of its worktree after it,
    /// worked out once.
    var pathsChangedLater: [ReviewLaterPathsKey: Set<String>] = [:]
    /// The keys of `pathsChangedLater` Git could not answer for.
    var pathsChangedLaterFailed: Set<ReviewLaterPathsKey> = []

    /// Lets go of the records of the worktrees `isGone` names, spelled as
    /// the keys spell them (`WindowRegistry.forgetProjectsGone`). A discard
    /// or an undo still running is kept: its end is on its way.
    func forget(roots isGone: (String) -> Bool) {
        hunkDiscards = hunkDiscards.filter { key, record in record == .running || !isGone(key.root) }
        pathsChangedLater = pathsChangedLater.filter { !isGone($0.key.root) }
        pathsChangedLaterFailed = pathsChangedLaterFailed.filter { !isGone($0.root) }
    }
}

/// What names the paths later turns changed after a review range
/// (`ReviewDiscardRecords.pathsChangedLater`): the range's worktree,
/// spelled one way (`WorktreePathResolver`), so its records go with
/// it, the range's end tree, and the latest later turn's.
struct ReviewLaterPathsKey: Hashable {
    let root: String
    let endTree: String
    let laterTree: String
}

/// Whether a review view's work, begun for the opening `begunFor` (its
/// first read), goes on past a wait: only while the view's task is not
/// canceled and the view still draws that opening, `drawing` now. The
/// reads it waits on return whether or not the view went, and a read that
/// went on would read the scope of whatever tab the window shows by then
/// into the review it began with.
enum ReviewViewWork {
    static func goesOn(begunFor opening: UUID?, drawing: UUID?, isCancelled: Bool) -> Bool {
        !isCancelled && opening == drawing
    }
}

/// A window's arrival with a parked review tab
/// (`ProjectWindowState.parkedReviewArrival`).
enum ParkedReviewArrival: Equatable {
    /// The switch is still placing the window, which stood, as the tab came
    /// back, on `left`, the place the person last looked at in the project.
    /// Where the switch lands, with whatever row or tab was asked for with
    /// it (⌘J, a notification, a card), is resolved once it is done, or
    /// as the target it carried is shown
    /// (`ProjectWindowState.resolveParkedReviewArrival`).
    case pending(left: ReviewArrival)
    /// Where the switch landed.
    case at(ReviewArrival)
}

/// Where a window stood: its row and tab (`ProjectWindowState.parkedReviewArrival`).
struct ReviewArrival: Equatable {
    let container: ContainerID
    let tabID: UUID?

    @MainActor
    init(_ selection: WindowSelection) {
        container = selection.activeContainerID
        tabID = selection.activeTabID
    }
}

/// What the review tab's view holds for itself and would lose as the view
/// goes: how its file list is laid out and filtered, which of its sections
/// are folded, which checked files the diff has opened again, the find bar,
/// and whether the comments from an earlier review are unfolded. The view keeps it beside its window as it changes
/// (`ProjectWindowState.reviewTabView`) and starts from it, so a tab that
/// went with its project and came back opens as it was left. Where the diff
/// is scrolled is not here: it is a position, read from the diff as the tab
/// goes (`ParkedReview.Tab.scroll`) and brought back once, as the rows it
/// names are read again. Nor is the line under the cursor, which
/// every fresh read of the open file's diff clears (`ReviewWorkspaceView`).
struct ReviewTabViewState: Equatable {
    var isTreeLayout = false
    var hidesViewedFiles = false
    /// The file list's filter field.
    var fileFilter = ""
    /// The file list's sections folded away (`ReviewFileRail`).
    var collapsedSections: Set<String> = []
    /// The checked files the stacked diff has opened again by hand.
    var openedViewedFiles = ReviewStackOpenedFiles()
    /// The find bar, its match counted again as the view reads its rows.
    var search = ReviewSearch()
    var areEarlierCommentsExpanded = false
}

/// A window's review tab as its views draw it (`ReviewTabViewState`), each
/// part observed on its own: the one model a view binds to directly, rather
/// than holding a copy and keeping the window's in step. The file list's
/// filter and folds are bound here; the parts other views still hold
/// themselves are written here as they change (`keptInReviewTab`). One per
/// window, for the review tab it shows: letting go of the tab starts it
/// anew, and a tab that went with its project hands its parts on
/// (`ParkedReview`) through `state`.
@MainActor
@Observable
final class ReviewTabDisplay {
    var isTreeLayout = false
    var hidesViewedFiles = false
    /// The file list's filter field.
    var fileFilter = ""
    /// The file list's sections folded away (`ReviewFileRail`).
    var collapsedSections: Set<String> = []
    var openedViewedFiles = ReviewStackOpenedFiles()
    var search = ReviewSearch()
    var areEarlierCommentsExpanded = false

    /// Every part at once: what a parked tab carries and brings back.
    /// Written part by part, and only where a part changes, so a view
    /// drawing one part is not redrawn for another's write.
    var state: ReviewTabViewState {
        get {
            ReviewTabViewState(
                isTreeLayout: isTreeLayout,
                hidesViewedFiles: hidesViewedFiles,
                fileFilter: fileFilter,
                collapsedSections: collapsedSections,
                openedViewedFiles: openedViewedFiles,
                search: search,
                areEarlierCommentsExpanded: areEarlierCommentsExpanded
            )
        }
        set {
            assign(\.isTreeLayout, newValue.isTreeLayout)
            assign(\.hidesViewedFiles, newValue.hidesViewedFiles)
            assign(\.fileFilter, newValue.fileFilter)
            assign(\.collapsedSections, newValue.collapsedSections)
            assign(\.openedViewedFiles, newValue.openedViewedFiles)
            assign(\.search, newValue.search)
            assign(\.areEarlierCommentsExpanded, newValue.areEarlierCommentsExpanded)
        }
    }

    /// Writes one part, only when it changes.
    func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ReviewTabDisplay, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}

/// Where a review tab's stacked diff was scrolled, for that tab only: its
/// opening (`ProjectWindowState.reviewScrollRestore`).
struct ReviewTabScroll: Equatable {
    let opening: UUID
    let anchor: ReviewScrollAnchor
}

/// The review a window left its project as it closed or switched to
/// another project (`WindowRegistry.leaveReview`), kept for that project
/// until a window shows the project again.
@MainActor
struct ParkedReview {
    /// The tabs kept, the one to come back first at their head (`joining`): a
    /// project has one review tab, so at most one, unless comments being
    /// written met in the project. None is dropped for another then; each
    /// comes back in turn (`WindowRegistry.takeParkedReview`).
    let tabs: [Tab]

    /// The tab that comes back first.
    var tab: Tab? {
        tabs.first
    }

    /// The first tab whose agent's pane is on `row` now, the one a window
    /// standing or arriving there takes; `nil` with none.
    func index(onRow row: ContainerID, in session: WorkspaceSession) -> Int? {
        tabs.firstIndex { $0.review.agentPaneID.flatMap { session.tab(containing: $0)?.container } == row }
    }

    /// Opens the tab at `index`, the first unless said, in `window`,
    /// behind, in place of whatever review it has, and returns what is left
    /// kept. The arrival is settled where the window stands, so the move
    /// that brought it there does not close the tab; the person's next move
    /// follows the usual rule.
    func opening(at index: Int = 0, in window: ProjectWindowState) -> ParkedReview? {
        guard tabs.indices.contains(index) else { return self }
        var rest = tabs
        let tab = rest.remove(at: index)
        if window.review != nil {
            window.letGoOfReview()
        }
        tab.open(in: window, isShown: false)
        window.parkedReviewArrival = .at(ReviewArrival(window.selection))
        return rest.isEmpty ? nil : ParkedReview(tabs: rest)
    }

    /// Which tab a window leaving a project hands it.
    enum TabKept {
        /// The tab, whatever it holds: a window switching in place.
        case always
        /// Only a tab with a comment being written in it: a window closing.
        case withComment
        /// None: a scratch pane's review, which stays with the window.
        case none
    }

    /// The tabs a project keeps once `left` joins `earlier`, the tabs it
    /// kept already. The one left last comes back first: it is what the
    /// person saw of the project last. A tab whose review holds a comment
    /// now is never dropped (a read that ended while it was kept can have
    /// let its comment go); one without gives way to the others, as opening
    /// a review replaces a tab that holds no comment.
    static func tabs(_ left: Tab?, joining earlier: [Tab]) -> [Tab] {
        kept((left.map { [$0] } ?? []) + earlier)
    }

    /// The tabs a place keeps once `moved`, kept elsewhere until its
    /// agent's tab was dragged to this place's row, joins `existing`:
    /// behind them, as it is no news of this place, so the one the person
    /// left here last still comes back first, unless only `moved` holds a
    /// comment. No comment is dropped.
    static func tabs(_ existing: [Tab], joinedBy moved: Tab) -> [Tab] {
        kept(existing + [moved])
    }

    /// `all` with every tab holding a comment, else only the first.
    private static func kept(_ all: [Tab]) -> [Tab] {
        let withComments = all.filter { $0.session?.holdsComment ?? false }
        return withComments.isEmpty ? Array(all.prefix(1)) : withComments
    }

    /// A review tab as its window left it: what it reads, and everything the
    /// window held beside it for it, so it comes back as it was.
    @MainActor
    struct Tab {
        /// What the tab reads, and whether it was in front.
        let review: ReviewTabState
        /// The review the tab showed, alive so the file open, the comments
        /// read, and the comment being written come back as they were
        /// (`ReviewSession.composer`); it keeps the tab's range open
        /// meanwhile (`WindowRegistry.reviewTurnRanges`).
        let session: ReviewSession?
        let outsideTurnsRead: ReviewTabModel.OutsideTurnsRead?
        /// How the diff was laid out, and how wide the file list was.
        let diffLayout: ReviewDiffLayout
        let railWidth: CGFloat
        let view: ReviewTabViewState
        /// Where the stacked diff was scrolled, by the line at its top:
        /// put back once the tab is drawn again and the file
        /// it names is read again (`ReviewDiffTable.stackRestore`). `nil`
        /// for a tab whose diff was not drawn.
        let scroll: ReviewScrollAnchor?

        /// The review tab `window` has open, `nil` without one, or when
        /// `kept` keeps none of it.
        ///
        /// What the stacked diff read goes: the review reads its list
        /// again as the tab comes back, and kept, the files read would
        /// stay until the app quits for every project left with a review
        /// open. The open file, the comments, the comment being written,
        /// and the read marks stay.
        init?(leftBy window: ProjectWindowState, kept: TabKept) {
            let isKept = switch kept {
            case .always: true
            case .withComment: window.reviewHasUnsavedComment
            case .none: false
            }
            guard isKept, let review = window.review else { return nil }
            self.review = review
            // A place the tab came back with and has not put back yet is
            // still where it stands: its diff may not be drawn yet, or not
            // have read the place's file. Else the diff's own place, read
            // before the stack is let go of, while it draws the rows the
            // anchor names.
            let pending = window.reviewScrollRestore.flatMap { $0.opening == review.opening ? $0.anchor : nil }
            scroll = pending ?? window.readReviewScroll?()
            session = window.reviewSession
            session?.releaseStack()
            outsideTurnsRead = window.reviewOutsideTurnsRead
            diffLayout = window.reviewPresentation.diffLayout
            railWidth = window.reviewPresentation.railWidth
            view = window.reviewTabView
        }

        /// Opens the tab in `window`, which holds no review: in front only
        /// when `isShown`, with its comment, which its review holds. Its
        /// stack reads again from now on (`ReviewSession.resumeStack`).
        /// ⌘⏎ starts from a gate of its own: the band is drawn anew once
        /// the review has read its list again, and waits as any band new on
        /// screen does.
        func open(in window: ProjectWindowState, isShown: Bool) {
            var review = review
            review.isShown = isShown
            session?.resumeStack()
            window.reviewSession = session
            window.review = review
            window.reviewOutsideTurnsRead = outsideTurnsRead
            window.reviewBandGate = ReviewBandGate()
            window.reviewTabView = view
            window.reviewScrollRestore = scroll.map { ReviewTabScroll(opening: review.opening, anchor: $0) }
            window.reviewPresentation.diffLayout = diffLayout
            window.reviewPresentation.railWidth = railWidth
            window.reviewPresentation.open(
                URL(fileURLWithPath: review.root, isDirectory: true),
                originPaneID: review.destinationPaneID,
                initialScope: review.scope
            )
        }
    }
}
