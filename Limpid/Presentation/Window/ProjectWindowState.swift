// ProjectWindowState.swift
// Limpid — one window's display-only state, beside its saved selection.

import CoreGraphics
import Foundation
import Observation

/// What one window shows that is never saved. The saved part (the selected
/// tab, the sidebar width, the frame) lives on `WindowSelection` in Core,
/// so persistence never depends on this layer; this type holds the
/// window's own and adds what only the screen needs.
@MainActor
@Observable
final class ProjectWindowState: Identifiable {
    let id: WindowID
    /// The window's selection, the one the session keeps under `id`,
    /// handed over as the window is listed (`WindowRegistry.addWindow`).
    /// Held rather than looked up so a view of this window reads its own
    /// selection, never a fallback: once the session no longer lists the
    /// window, its views read what it showed last, and no other window's.
    let selection: WindowSelection

    /// Whether the window is hidden: the last window shown, closed, is
    /// hidden rather than ended so the Dock brings it back where it was.
    /// Changed only through `WindowRegistry` (`show`, `hide`, a window
    /// taking the keyboard), which tells the session so the two agree.
    var isHidden = false
    /// Where ⌘J is in the attention list for this window. Each window walks
    /// it on its own.
    var cursor = AttentionCursorState()
    /// The item each pane's decision bar is on, by pane, once one was
    /// chosen: from the bar's count button, the Needs Attention list, or
    /// ⌘J. A pane without one shows its highest-ranked item.
    var decisionBarSelection: [UUID: AttentionItemID] = [:]
    /// What was just handled in a pane, while its bar says so. The
    /// person moving on (⌘J, the list, another pane) clears it, and so does
    /// a turn starting in the pane or its agent leaving (`runsChanged`).
    var decisionBarDone: [UUID: DecisionBarContent.DoneResult] = [:]
    /// A "Done" line waiting for its pane's bar to have nothing left to
    /// show: "Mark as Viewed" in the review tab closes the tab, and the bar
    /// drawn again under it can still list the unread turn it marked for a
    /// moment before the list catches up; so can the bar a restore strip
    /// gives way to, for the turns the restore took back. Taken up when
    /// the pane's items are gone; dropped when the person moves on, or when
    /// a turn starts in the pane or its agent leaves (`runsChanged`).
    var pendingDecisionBarDone: [UUID: DecisionBarContent.DoneResult] = [:]
    /// The restore strip each pane's bar shows in place of its line, while
    /// one is open.
    var restoreStrips: [UUID: RestoreStrip] = [:]
    /// What became of the hunks discarded, and the paths later turns
    /// changed: the app's one store, which every window shares
    /// (`WindowRegistry.reviewDiscards`), as a worktree's records are the
    /// worktree's. The review diffs a range's trees, which a discard does
    /// not change, so the hunk stays on screen and says it was discarded.
    let reviewDiscards: ReviewDiscardRecords
    /// What became of each hunk discarded (`reviewDiscards`).
    var hunkDiscards: [ReviewHunkKey: ReviewHunkDiscardRecord] {
        get { reviewDiscards.hunkDiscards }
        set { reviewDiscards.hunkDiscards = newValue }
    }

    /// The paths changed after a review range (`reviewDiscards`).
    var pathsChangedLater: [ReviewLaterPathsKey: Set<String>] {
        get { reviewDiscards.pathsChangedLater }
        set { reviewDiscards.pathsChangedLater = newValue }
    }

    /// The keys of `pathsChangedLater` Git could not answer for.
    var pathsChangedLaterFailed: Set<ReviewLaterPathsKey> {
        get { reviewDiscards.pathsChangedLaterFailed }
        set { reviewDiscards.pathsChangedLaterFailed = newValue }
    }

    /// The pane whose restore strip takes the keyboard next, so Return
    /// restores and Escape cancels; taken once by that strip.
    var restoreFocusRequest: UUID?
    /// What each pane's bar shows and since when, for ⌘⏎. Not
    /// observed: nothing is drawn from it.
    @ObservationIgnored var primaryActionGate = PrimaryActionGate()

    /// Global frame of this window's palette field, which the palette's
    /// dropdown hangs from. Each window has its own field, so one frame
    /// for the app would put the dropdown under whichever field reported
    /// last. Excluded from observation so window resizes don't redraw
    /// every view that reads this window.
    @ObservationIgnored var paletteFieldFrame: CGRect = .zero
    /// The Needs Attention pill's frame, which the list hangs from when ⌃⌘J
    /// opens it rather than a click. Not observed: it moves with every
    /// resize, and only the next key press reads it.
    @ObservationIgnored var needsAttentionAnchor: CGRect = .zero
    /// The frame of the pane strip's Open Tabs button, which the list hangs
    /// from when ⇧⌘A opens it; not observed, for the same reason. `.zero`
    /// until the window has shown a strip.
    @ObservationIgnored var openTabsAnchor: CGRect = .zero
    /// Asks the sessions sidebar to take the keyboard (⌥⌘0); each
    /// request is new, so asking twice moves the keyboard twice.
    var sidebarFocusRequest: UUID?
    /// The sidebar's lines in sight, as it last reported them: whether the
    /// selected row needs bringing into view after a switch. Not
    /// observed: it changes with every line scrolled past, and only that
    /// switch reads it. The sidebar's place is the window's, not the
    /// project's, since it lists every project
    /// (`ProjectScrollMemory`).
    @ObservationIgnored var sidebarVisibleLines: Set<SidebarItemID> = []
    /// The pointer is over the sidebar. With the keyboard in the sidebar
    /// and a drag, one of the holds on its sections (`SidebarSectionHold`).
    var isPointerInSidebar = false
    /// The sidebar has the keyboard (⌥⌘0).
    var isSidebarKeyboardActive = false
    /// The sections the sidebar shows its rows in, every project's, as last
    /// drawn: what a hold keeps. The one value the sidebar, ⌃⌘1…9, and ⌘[ ⌘] read, through
    /// `presentedSections(computed:isDragging:)`, so the rows they count are
    /// the rows in sight. Not observed: it is written as the sidebar draws,
    /// and what changes it (the rows, the holds) is observed already.
    @ObservationIgnored private(set) var presentedSections = SidebarPresentedSections()
    /// The rows `presentedSections` lists among the working ones, observed
    /// where `presentedSections` is not: the menus that count the working
    /// rows (⌃⌘1…9 on or off, ⌘[ ⌘]) read it so they follow a row moving in
    /// or out of them as the sidebar draws it, and only such a move rebuilds
    /// them, not every Git and forge reading.
    private(set) var presentedWorkingRows: Set<ContainerID> = []

    /// The sections to show now, from where each row belongs by what it
    /// holds (`computed`): the shown ones while something holds them,
    /// the selected row among the working rows either way.
    func presentedSections(computed: SidebarPresentedSections, isDragging: Bool) -> SidebarPresentedSections {
        SidebarPresentedSections(sections: SidebarSectionHold.next(
            presented: presentedSections.sections,
            computed: computed.sections,
            isHeld: isPointerInSidebar || isSidebarKeyboardActive || isDragging,
            selected: selection.isChoosingProject ? nil : selection.activeContainerID
        ))
    }

    /// Records the sections the sidebar drew, or, while it is not drawn,
    /// the window's project's as they stand (`HiddenSidebarSectionsFollower`).
    func present(_ sections: SidebarPresentedSections) {
        presentedSections = sections
        let working = Set(sections.sections.filter { $0.value == .working }.keys)
        if working != presentedWorkingRows {
            presentedWorkingRows = working
        }
    }

    /// Lets `row` take the section it belongs in at once, hold or not: the
    /// person moved it themselves (Move to Other Worktrees), so it is not
    /// slipping away under them.
    func releaseHold(on row: ContainerID) {
        presentedSections.sections[row] = nil
    }

    /// Whether the window's rails are hidden from the View menu. The
    /// keys they hold keep working.
    var areRailsHidden = false
    /// Whether the all projects sheet is open over this window.
    var isAllProjectsPresented = false
    /// Whether a system sheet (the new worktree sheet, project settings,
    /// the clipboard confirmation, an alert) is attached to this window, as
    /// AppKit reports it (`AttachedSheetObserver`).
    var hasAttachedSheet = false

    /// Whether something lies over the whole window, so nothing under it
    /// may take the pointer: not a click, and not a hover either, which a
    /// system sheet lets through to the window behind it and the all
    /// projects scrim let through to the rails.
    var isContentCovered: Bool {
        isWindowOverlayPresented || hasAttachedSheet
    }

    /// Whether a panel Limpid draws over the whole window (All Projects,
    /// the keyboard shortcuts panel) is open: it has the person's
    /// attention, and VoiceOver reads it alone.
    var isWindowOverlayPresented: Bool {
        isAllProjectsPresented || keyboardShortcuts.isPresented
    }

    /// The title bar dropdown open in this window, if any.
    var titleBarMenu: TitleBarMenuRequest?
    /// The new worktree sheet of this window: asked for, or up.
    var newWorktreeSheet = NewWorktreeSheetSlot()
    /// The new worktree sheet's request, asked for or up, if any.
    var newSession: NewSessionSheetRequest? {
        newWorktreeSheet.request
    }

    /// Asks for the new worktree sheet on `request`
    /// (`NewWorktreeSheetSlot.open`); an open title bar dropdown closes as
    /// it opens.
    @discardableResult
    func openNewWorktreeSheet(
        _ request: NewSessionSheetRequest,
        introducesInstantKey: Bool = false
    ) -> NewWorktreeSheetSlot.Outcome {
        let outcome = newWorktreeSheet.open(
            request,
            isWindowCovered: hasAttachedSheet,
            introducesInstantKey: introducesInstantKey
        )
        if outcome == .opened {
            titleBarMenu = nil
        }
        return outcome
    }

    /// Whether ⌥⌘N is making a worktree in this window: its fetch and Git
    /// run with no sheet, and the menu item and a second ⌥⌘N wait for them.
    var isCreatingWorktreeAtOnce = false
    /// The control the notification history hangs from in this window: the
    /// rail's button. Each window has its own, so the panel opens beside the
    /// control in the window it was asked from. `nil` until the control has
    /// been laid out.
    var historyAnchor: NotificationHistoryAnchor?
    /// The notification history's sources opened past their fold. Held by
    /// the window rather than the panel's view, so a panel the overlay
    /// rebuilds keeps them; the overlay folds them again as the panel
    /// closes.
    var historyExpandedSources: Set<NotificationHistoryList.SourceID> = []
    /// The review tab of this window, while one is open: what it reads
    /// and where it goes back to. One per window; each window reads its own
    /// comparison.
    var review: ReviewTabState?
    /// The review the tab shows, kept while the tab is open so a change of
    /// scope keeps the session's place.
    /// Its draft is shared with every other review of the worktree
    /// (`ReviewDraftWriter`).
    var reviewSession: ReviewSession?
    /// How this window's review is laid out (rail width, layout, the
    /// opening it belongs to). The window's own, so two windows never draw
    /// each other's review. The rail width and the layout go with a review
    /// tab that goes with its project, and come back with it
    /// (`ParkedReview.Tab`).
    let reviewPresentation = ReviewPresentation()
    /// The floating surfaces drawn over this window: each window has
    /// its own, so a card, a rename field, or a panel opened in one is
    /// never drawn in another, and one window's open panel holds back no
    /// other window's.
    let prHover = PRHoverPresentation()
    /// The commands the menus, the palette, and the rails ask of this
    /// window, which its views carry out (`WindowCommand`).
    @ObservationIgnored let commands = WindowCommandChannel()
    /// The approval card and the frames of the sidebar's request rows it
    /// stands beside; the requests themselves are shared
    /// (`ApprovalPresentationStore`).
    let approvalCard = WindowApprovalCard()
    let paneRename = PaneRenamePresentation()
    let promptCachePanel = PromptCachePanelPresentation()
    let containerColor = ContainerColorPresentation()
    /// Whether this window's notification history is open; what it lists
    /// is shared (`NotificationHistoryStore`).
    let notificationHistory = NotificationHistoryPresentation()
    /// Whether this window's keyboard shortcuts panel is up: it opens in the
    /// window it was asked in, not in every window.
    let keyboardShortcuts = KeyboardShortcutPresentation()
    /// The changes outside turns as the review tab last read its list
    /// (`ReviewTabModel.OutsideTurnsRead`).
    var reviewOutsideTurnsRead: ReviewTabModel.OutsideTurnsRead?
    /// Whether the review tab holds a comment being written, or one set
    /// aside in its banner, which another entry must not replace: the review
    /// would refuse the new comparison and the tab would name one it is not
    /// showing. The tab's review holds it (`ReviewSession.holdsComment`), so
    /// it goes and comes back with the tab (`ParkedReview`).
    var reviewHasUnsavedComment: Bool {
        reviewSession?.holdsComment ?? false
    }

    /// Whether the review tab is in front, standing where the terminal
    /// was, so the window's panes are out of sight. The pane commands
    /// (split, equalize, zoom, focus a neighbor) are off then: they would
    /// change panes the person cannot see, and the change would only show
    /// on going back. The menu, the palette's rows, and the palette's run
    /// of a row ask this (`SupervisionPaletteFacts.arePanesHidden`).
    var arePanesHidden: Bool {
        review?.isShown == true
    }

    /// Where the window landed as a parked review tab came back to it, in
    /// front or behind, with the project the window switched to in place
    /// (`WindowRegistry.windowDidSwitchProject`). The switch moves the
    /// window to the project, and to whatever row or tab was asked for
    /// with it, in that same pass; none of that is the person going to a
    /// terminal or to another row, so the switch never closes the tab
    /// (`isParkedReviewArrival`). Pending until the switch is done, or
    /// until the target it carried is shown (`resolveParkedReviewArrival`),
    /// which settles it where the window stands. Forgotten at the first
    /// look from anywhere else, and as the review tab closes or reads
    /// another comparison (`ReviewTabActions`), so it never answers for a
    /// later move of the person's back to the same place. A tab handed to
    /// the window where it stands, or as it arrives at a row it waits for,
    /// comes settled where the window stands (`ParkedReview.opening(at:in:)`).
    @ObservationIgnored var parkedReviewArrival: ParkedReviewArrival?
    /// Whether the registry has let the window go. What its views
    /// still report as they go is not taken.
    @ObservationIgnored private(set) var isClosed = false
    /// The open the window is waiting for (it finds the repository first),
    /// with where the person was when it was asked for: it lands only if
    /// they are still there, so a late answer never covers where they went.
    @ObservationIgnored var reviewOpenRequest: ReviewOpenRequest?

    /// When ⌘⏎ performs the review tab's "Mark as Viewed". Not
    /// observed: nothing is drawn from it.
    @ObservationIgnored var reviewBandGate = ReviewBandGate()
    /// The review tab as its views draw it, each part observed on its own:
    /// the file list binds to it, and the views that hold a part themselves
    /// write it here as it changes, so a tab that goes with its project
    /// hands it on (`ParkedReview`) and the view drawn for it again starts
    /// from it. One for the window's life, handed to its views.
    let reviewTabDisplay = ReviewTabDisplay()

    /// Every part of `reviewTabDisplay` at once.
    var reviewTabView: ReviewTabViewState {
        get { reviewTabDisplay.state }
        set { reviewTabDisplay.state = newValue }
    }

    /// Reads where the review tab's stacked diff is scrolled now: handed
    /// over by the diff drawing the tab (`ReviewDiffTable.onScrollReader`),
    /// read only as the tab goes with its project (`ParkedReview.Tab`), so
    /// scrolling costs nothing here. `nil` while no diff draws the tab, and
    /// let go of as the tab is replaced by another opening
    /// (`ReviewTabActions.apply`), so it never answers for another review.
    @ObservationIgnored var readReviewScroll: (@MainActor () -> ReviewScrollAnchor?)?
    /// Where a review tab that came back to the window was scrolled, by the
    /// tab's opening, until its diff has put it back or the person moved
    /// first (`ReviewWorkspaceView.takeStackRestore`). Only a view drawn
    /// for that opening takes it, and the tab going again before then
    /// takes it along (`ParkedReview.Tab`).
    @ObservationIgnored var reviewScrollRestore: ReviewTabScroll?

    /// Where the changes panel stands now: written by the panel as it
    /// scrolls, and kept for the project as the window leaves it (`WindowRegistry.scrollMemories`). Not observed: nothing
    /// is drawn from it, and it changes with every row scrolled past.
    @ObservationIgnored var scrollPlace = ProjectScrollReport()
    /// What the window brings back of the lists of the project it has just
    /// switched to (`ProjectScrollRestore`); replaced by the next switch.
    /// Observed, so a list drawn for the project hears of it.
    var scrollRestore: ProjectScrollRestore?
    /// The lists that still have to take their part of `scrollRestore`.
    /// Not observed: a list taking its part redraws no other.
    @ObservationIgnored var pendingScrollLists: Set<ProjectScrollList> = []

    /// Takes `list`'s part of the restore for the project the window shows,
    /// once: `nil` when there is none to take (no switch since, another
    /// project's, the list not on screen as the window landed, or taken).
    func takeScrollRestore(for list: ProjectScrollList) -> ProjectScrollRestore? {
        guard let restore = scrollRestore, restore.projectID == selection.shownProjectID,
              pendingScrollLists.remove(list) != nil
        else { return nil }
        return restore
    }

    /// How the changes panel (`WindowSelection.isChangesPanelPresented`)
    /// shares the window with the terminal
    /// (`ChangesPanelLayoutRule`): as drawn while open, and as it would open
    /// while closed, so it opens straight into the right place. Decided
    /// again while open only as the window is resized, the person acts on
    /// the sidebar or the panel, or the shown tab's panes change in place;
    /// a switch to another project, workspace, or tab keeps it
    /// (`ChangesPanelLayoutRule.redecides`, `settleChangesPanelLayout`).
    var changesPanelLayout: ChangesPanelLayout = .beside
    /// What `changesPanelLayout` was last decided against, which tells a
    /// move to another tab from a change of the window or its panes; `nil`
    /// before the first decision. Not observed: nothing draws it.
    @ObservationIgnored var changesPanelLayoutBasis: ChangesPanelLayoutRule.Basis?
    /// The font's cell width as a pane's surface last read it, for the
    /// layout to count columns by while no surface can be read: the review
    /// tab covers the panes, so theirs have no window. The window's rather
    /// than its view's, so a switch works the layout out before the view
    /// draws. `nil` until a surface has been read.
    var changesPanelCellWidth: CGFloat?
    /// Whether the person asked for the sidebar while the panel had folded
    /// it (⌘B, its rail button, ⌥⌘0): it stays until the panel closes,
    /// through a switch to another project too, as the panel and the
    /// sidebar are the window's.
    var isSidebarKeptOverPanel = false
    /// The width the sidebar, the session, and the panel share, which no
    /// layout of the panel changes (`ChangesPanelLayoutRule.Input`).
    var changesPanelSharedWidth: CGFloat = 0

    /// Whether the panel, while `isPresented`, has folded the sidebar,
    /// which the session header says.
    func isSidebarFoldedForChanges(isPresented: Bool) -> Bool {
        isPresented && changesPanelLayout == .besideHidingSidebar
    }

    /// Whether the sidebar is on screen: the person's choice, folded for
    /// now while the panel needs its room. What the window draws.
    var isSidebarShown: Bool {
        !selection.sidebarHidden && !isSidebarFoldedForChanges(isPresented: selection.isChangesPanelPresented)
    }

    /// Whether the sessions sidebar is on screen, reserved or laid over the
    /// content in a narrow window, as the layout last resolved it. The
    /// saved preference alone says nothing about the overlay, so the rail
    /// reads this to show its button pressed.
    var isSidebarPresented = true

    /// `reviewDiscards` is the store the window's reviews share with every
    /// other window's; one of its own where nothing else reads them (a test
    /// of one window).
    init(selection: WindowSelection, reviewDiscards: ReviewDiscardRecords = ReviewDiscardRecords()) {
        id = selection.windowID
        self.selection = selection
        self.reviewDiscards = reviewDiscards
    }

    /// Marks the window let go (`WindowRegistry.close`).
    func markClosed() {
        isClosed = true
    }

    // MARK: - Review tab

    /// Lets go of the review tab and everything held beside it for it: the
    /// tab closes, or went with its project (`ParkedReview`). The discards
    /// stay, in the store every window shares (`reviewDiscards`).
    func letGoOfReview() {
        review = nil
        reviewSession = nil
        parkedReviewArrival = nil
        reviewOutsideTurnsRead = nil
        reviewBandGate = ReviewBandGate()
        reviewTabView = ReviewTabViewState()
        readReviewScroll = nil
        reviewScrollRestore = nil
        reviewPresentation.close()
    }

    /// Settles where the switch that brought a parked review tab back landed
    /// the window: the one place that decides whether the tab comes back in
    /// front. A switch that carries a target (⌘J, a notification, an
    /// attention list or approval card, a menu bar row)
    /// asks to show it, so the tab goes behind, never closed, even where
    /// the target is the place the person left: the entry settles it as it
    /// shows the target (`ReviewTabActions.putBehind`), `showsTarget`. A
    /// switch with no target (project ▾, ⌘O, the palette's projects, a
    /// recent project, a card with no item, going back or forward to
    /// another project's tab) is settled once it is done: on the place the
    /// person last looked at in the project, the tab stays as it was left,
    /// in front or behind; anywhere else (that place is gone, or the card
    /// or the history named another row or tab), it goes behind.
    func resolveParkedReviewArrival(showsTarget: Bool = false) {
        guard case let .pending(left) = parkedReviewArrival else { return }
        let landed = ReviewArrival(selection)
        if showsTarget || landed != left, review?.isShown == true {
            review?.isShown = false
        }
        parkedReviewArrival = .at(landed)
    }

    /// Whether the window's selection is where it landed as a parked review
    /// tab came back to it (`parkedReviewArrival`). The first look after
    /// the switch takes where it landed; the first time it is not there,
    /// the arrival is forgotten: from then on, a move is the person's.
    func isParkedReviewArrival() -> Bool {
        resolveParkedReviewArrival()
        switch parkedReviewArrival {
        case nil, .pending:
            return false
        case let .at(arrival):
            if arrival == ReviewArrival(selection) {
                return true
            }
            parkedReviewArrival = nil
            return false
        }
    }

    // MARK: - Decision bars

    /// The pane with the keyboard in this window moved on from `pane`:
    /// another pane, tab, or session. Its "Done" line ends and the item
    /// chosen for it gives way, so coming back without choosing shows the
    /// highest-ranked one. ⌘J and the Needs Attention list choose for the
    /// pane they go to before going, so that choice is kept. Decided here,
    /// from the window's own selection, rather than from a bar coming and
    /// going: a bar is drawn anew on a split or a zoom, and none is drawn
    /// while review covers its pane, without the person having moved.
    /// Choices for panes the session no longer has (`livePanes`) go too.
    func keyboardMoved(from pane: UUID?, livePanes: Set<UUID>) {
        if let pane {
            forgetDecisionBarChoices(paneID: pane)
        }
        for gone in Set(decisionBarSelection.keys).union(decisionBarDone.keys).union(pendingDecisionBarDone.keys)
            where !livePanes.contains(gone)
        {
            forgetDecisionBarChoices(paneID: gone)
        }
        // A strip stays while the person looks elsewhere, and goes with
        // its pane.
        for gone in restoreStrips.keys where !livePanes.contains(gone) {
            restoreStrips[gone] = nil
        }
    }

    /// An item a pane's bar showed, and the epoch the pane was in then
    /// (`PaneRunLedger.epoch(inPane:)`); `nil` when no run was in it.
    struct ShownItem: Equatable {
        let item: AttentionItem
        let epoch: Int?
    }

    /// A change of one pane's items, as its bar sees it.
    struct ItemsChange {
        let paneID: UUID
        let items: [AttentionItem]
        /// What the bar showed before the change.
        let lastShown: ShownItem?
        /// The epoch the pane is in now. One that differs from the shown
        /// item's, or that either lacks, means the pane moved on since.
        let epoch: Int?
        /// Whether the shown item's run was declined at its prompt rather
        /// than answered there (`DecisionBarModel.isDeclined(runtime:turn:)`).
        var isDeclined = false

        /// Both lacking (no run in the pane as the item was shown, nor now)
        /// counts as moved on too: no run of the pane can have answered the
        /// item, so a "Done" line would claim what nothing showed.
        var hasMovedOnSinceShown: Bool {
            lastShown.map { $0.epoch == nil || $0.epoch != epoch } ?? false
        }
    }

    /// The items of a pane changed. The "Done" line is set, kept, or
    /// cleared (`DecisionBarModel.doneUpdate`); a line left pending is taken
    /// up or dropped; a choice of an item that left is dropped.
    ///
    /// - Parameters:
    ///   - isSelectedPane: whether the pane has the keyboard in this window.
    ///     Only there is a line set: a split's other leaf would keep it
    ///     until ⌘J or the list.
    ///   - isCurrent: whether a line still says something true (a
    ///     restore's, while the pane's record is that restore).
    func itemsChanged(
        _ change: ItemsChange,
        isSelectedPane: Bool,
        isCurrent: (DecisionBarContent.DoneResult) -> Bool
    ) {
        let (paneID, items) = (change.paneID, change.items)
        let hasMovedOn = change.hasMovedOnSinceShown
        let lastShown = change.lastShown
        switch DecisionBarModel.doneUpdate(
            lastShown: lastShown?.item,
            items: items,
            hasMovedOnSinceShown: hasMovedOn,
            isDeclined: change.isDeclined
        ) {
        case .keep: break
        case .clear:
            if decisionBarDone[paneID] != nil {
                decisionBarDone[paneID] = nil
            }
        case let .set(result) where isSelectedPane: decisionBarDone[paneID] = result
        case .set: break
        }
        // A "Done" the bar set since is newer than one left by the review
        // tab, and keeps the bar. An insert's line shows over the pane's
        // items, until they change.
        if let pending = pendingDecisionBarDone[paneID], !isCurrent(pending) {
            pendingDecisionBarDone[paneID] = nil
        } else if let pending = pendingDecisionBarDone[paneID] {
            let isTaken = DecisionBarContent.takes(pending, over: items)
            // An insert's line is true only just after it: one the bar
            // cannot show now would later say "Press Return" about comments
            // sent long since.
            if isTaken || pending.showsOverItems {
                pendingDecisionBarDone[paneID] = nil
            }
            if isTaken, decisionBarDone[paneID] == nil {
                decisionBarDone[paneID] = pending
            }
        }
        if let selected = decisionBarSelection[paneID], !items.contains(where: { $0.id == selected }) {
            decisionBarSelection[paneID] = nil
        }
    }

    /// The runs in `panes` moved on (`PaneRunLedger.note`): a turn began
    /// there, or the agent left. Their "Done" lines end, shown or pending,
    /// since each says what was true just after the person acted
    /// ("Press Return to send"), not after the agent moved on. The
    /// item chosen for the pane stays: the bar drops it once it is gone.
    func runsChanged(inPanes panes: Set<UUID>) {
        for paneID in panes {
            if decisionBarDone[paneID] != nil {
                decisionBarDone[paneID] = nil
            }
            if pendingDecisionBarDone[paneID] != nil {
                pendingDecisionBarDone[paneID] = nil
            }
        }
    }

    /// Ends the pane's "Done" line and drops the item chosen for it, so the
    /// bar shows the highest-ranked one. Written only when there is
    /// something to clear: each write tells every bar of the window to draw
    /// again.
    func forgetDecisionBarChoices(paneID: UUID) {
        if decisionBarDone[paneID] != nil {
            decisionBarDone[paneID] = nil
        }
        if pendingDecisionBarDone[paneID] != nil {
            pendingDecisionBarDone[paneID] = nil
        }
        if decisionBarSelection[paneID] != nil {
            decisionBarSelection[paneID] = nil
        }
    }
}

extension ProjectWindowState {
    /// Runs `body` with `request` as the open the window waits for, and
    /// clears it however `body` ends (no repository, the person moved on,
    /// the tab opened) unless a later open took its place: a request left
    /// standing has the window passed over for a review another window
    /// parks (`WindowRegistry.keep`).
    func openingReview<T>(_ request: ReviewOpenRequest, _ body: () async -> T) async -> T {
        reviewOpenRequest = request
        defer {
            if reviewOpenRequest == request {
                reviewOpenRequest = nil
            }
        }
        return await body()
    }
}

/// The layers a window shows over its content, of which one is open at a
/// time: what is open goes as another comes. The palette is the
/// session's (`WorkspaceSession.commandPaletteState`), counted here while
/// it names this window.
enum WindowLayer: CaseIterable, Hashable {
    case palette
    case titleBarMenu
    case notificationHistory
    case allProjects
    case keyboardShortcuts

    /// The panels drawn over the whole window, which hold its keyboard
    /// (`ProjectWindowState.isWindowOverlayPresented`).
    static let windowOverlays = Set(WindowOverlay.allCases.map(\.layer))
}

/// A panel drawn over the whole window: the layers
/// `ProjectWindowState.openWindowOverlay` opens. Its own type, so that a
/// layer it cannot open (the palette, a menu) cannot be asked of it.
enum WindowOverlay: CaseIterable, Hashable {
    case allProjects
    case keyboardShortcuts

    var layer: WindowLayer {
        switch self {
        case .allProjects: .allProjects
        case .keyboardShortcuts: .keyboardShortcuts
        }
    }
}

extension ProjectWindowState {
    /// The layers open over this window now.
    func openLayers(session: WorkspaceSession) -> Set<WindowLayer> {
        let states: [(WindowLayer, Bool)] = [
            (.palette, session.commandPaletteState?.windowID == id),
            (.titleBarMenu, titleBarMenu != nil),
            (.notificationHistory, notificationHistory.isPresented),
            (.allProjects, isAllProjectsPresented),
            (.keyboardShortcuts, keyboardShortcuts.isPresented)
        ]
        return Set(states.filter(\.1).map(\.0))
    }

    /// Whether a layer other than `layer` is open, which `layer` gives way
    /// to: that layer has the keyboard, so `layer` closes without handing
    /// it back.
    func isAnotherLayerOpen(than layer: WindowLayer, session: WorkspaceSession) -> Bool {
        !openLayers(session: session).subtracting([layer]).isEmpty
    }

    /// Opens a panel over the whole window, closing every other layer
    /// first. The other layers open from their own requests (a palette's
    /// query, a menu's anchor) and close an overlay by being open
    /// (`isAnotherLayerOpen`).
    func openWindowOverlay(_ overlay: WindowOverlay, session: WorkspaceSession) {
        closeLayers(Set(WindowLayer.allCases).subtracting([overlay.layer]), session: session)
        switch overlay {
        case .allProjects: isAllProjectsPresented = true
        case .keyboardShortcuts: keyboardShortcuts.isPresented = true
        }
    }

    /// Closes `layers` where they are open. Each is written only when it
    /// changes, so an observer of a closed layer is not woken.
    func closeLayers(_ layers: Set<WindowLayer>, session: WorkspaceSession) {
        if layers.contains(.palette), session.commandPaletteState?.windowID == id {
            session.commandPaletteState = nil
        }
        if layers.contains(.titleBarMenu), titleBarMenu != nil {
            titleBarMenu = nil
        }
        if layers.contains(.notificationHistory), notificationHistory.isPresented {
            notificationHistory.isPresented = false
        }
        closeWindowOverlays(layers)
    }

    /// Closes the panels over the whole window among `layers`, which need
    /// no session to close.
    func closeWindowOverlays(_ layers: Set<WindowLayer> = WindowLayer.windowOverlays) {
        if layers.contains(.allProjects), isAllProjectsPresented {
            isAllProjectsPresented = false
        }
        if layers.contains(.keyboardShortcuts), keyboardShortcuts.isPresented {
            keyboardShortcuts.isPresented = false
        }
    }
}
