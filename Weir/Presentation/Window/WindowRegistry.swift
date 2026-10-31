// WindowRegistry.swift
// Weir — the main windows that exist, which one commands act on, and what they show.

import Foundation
import Observation
import OSLog
import WeirDomain

private let log = Logger.weir("window.registry")

/// Every main window's display state, and the pane visibility they report.
///
/// Each window shows one project at a time, and a project is shown in one
/// window at a time: the person's choice of another project
/// switches the window in place, or brings forward the window that shows
/// it (`show(project:in:from:intent:)`, `connectProjectSwitching`). A
/// window is made only when the person asks for one: New Window, which
/// shows nothing (`openEmptyWindow`), and a project ⌘-clicked or chosen
/// with ⌘Return (`openInNewWindow`). The primary is the window the
/// app opens at launch. Closing a window ends it while another is shown;
/// the last one shown is hidden instead, so the Dock brings it back as it
/// was (`close`). The primary is a role, handed on as its window closes.
@MainActor
@Observable
final class WindowRegistry {
    /// The windows, the primary first.
    private(set) var windows: [ProjectWindowState]
    /// The window that has the primary's role: the first at launch, then
    /// a window left as it closes (`makePrimary`).
    private(set) var primary: ProjectWindowState
    /// The reviews windows left their projects as they closed or switched
    /// to another project, by project, until a window shows that project
    /// again (`takeParkedReview`). Not observed: nothing draws them.
    @ObservationIgnored private(set) var parkedReviews: [UUID: ParkedReview] = [:]
    /// The review tabs that wait for the scratch row, each with a comment
    /// being written in it, as a project's wait for the project
    /// (`parkedReviews`): where a review waits whose agent's pane is on the
    /// scratch row as its window lets it go, whatever project the window
    /// showed, or whose pane is gone, a scratch pane's, or a project's left
    /// by a window that showed none (`parkReview`, `waitingPlace`). A
    /// window takes the first, behind, as it arrives at the scratch row
    /// (`takeParkedReview(arrivingAt:in:)`), or stands there with no
    /// review as one is kept, or as a review opens on a scratch tab
    /// (`takeParkedReviewBeforeOpening`).
    @ObservationIgnored private(set) var parkedScratchReview: ParkedReview?
    /// Where windows had each project's lists scrolled as they left it
    /// (switching in place, or closing), by project, until a window shows
    /// the project again. Like the project's view
    /// (`WorkspaceSession.projectViews`), a key is a project no window shows:
    /// the window that shows it holds its positions in its lists. Never
    /// saved. Not observed: nothing draws it.
    ///
    /// Kept so by the two ways a window takes or leaves a project: a switch
    /// in place (`windowWillSwitchProject`, `windowDidSwitchProject`) and a
    /// window ending (`end`). A new window opened on a project takes it the
    /// first way, listed before it switches (`openInNewWindow`,
    /// `ProjectSwitchHandlers.didAddWindow`). Any other way for a window to
    /// take a project goes through `WorkspaceSession.showProject` too, or
    /// takes the project's entry here and in `parkedReviews` itself: an
    /// entry left for a project a window shows would come back on a later
    /// switch, from another visit.
    @ObservationIgnored private var scroll = ProjectScrollMemories()

    /// What `scroll` keeps, by project.
    var scrollMemories: [UUID: ProjectScrollMemory] {
        scroll.byProject
    }

    /// What became of the hunks discarded in every window's reviews: one
    /// store, which every window shares (`ProjectWindowState.reviewDiscards`),
    /// as a worktree's records are the worktree's.
    let reviewDiscards: ReviewDiscardRecords
    /// How the discards' worktrees are spelled: the app's one resolver
    /// (`AppState.worktreePaths`), which lets go of a removed project's
    /// spellings as its discards go.
    let worktreePaths: WorktreePathResolver
    /// The session's projects as the registry last saw them
    /// (`forgetProjectsGone`): a project removed is gone from the session
    /// with its folders, which say whose discards go with it.
    @ObservationIgnored private var knownProjects: [Project] = []
    /// The panes whose terminals draw, per window and across windows.
    private(set) var visibility = PaneVisibility()
    /// Whether the person can be said to see each pane: the attended panes
    /// of on-screen windows, and the app-wide facts set by the app layer.
    private(set) var attention = AttentionVisibility()
    /// The attended panes each window last reported, kept like
    /// `reportedPanes` so a window coming back on screen counts again.
    @ObservationIgnored private var attendedByWindow: [WindowID: Set<UUID>] = [:]
    /// The runs in each pane at the last pass, for every window. Written
    /// only by `noteRuns`; read through `epoch(inPane:)`.
    @ObservationIgnored private(set) var paneRuns = PaneRunLedger()
    /// Set by the app layer, which owns the AppKit windows. `nil` in tests,
    /// which make none.
    var presenter: (any ProjectWindowPresenting)?
    /// Where the union of visible panes goes. Set by the app layer to the
    /// surface registry.
    @ObservationIgnored weak var occlusion: (any PaneOcclusionApplying)?
    /// Told whenever a window is hidden or shown again, with whether it is
    /// hidden: the session leaves out what a hidden window would draw
    /// (`WorkspaceSession.hiddenWindowIDs`). Set by the app layer.
    @ObservationIgnored var onVisibilityChange: ((WindowID, Bool) -> Void)?
    /// Told whenever a main window takes the keyboard. Set by the app
    /// layer, for what follows the keyboard.
    @ObservationIgnored var onKeyWindowChange: ((WindowID) -> Void)?
    /// Told when a window is about to be hidden, before it leaves the
    /// screen. Set by the app layer, which closes the window's review there
    /// (`ReviewTabActions.windowHidden`): a view watching `isHidden` is not
    /// updated reliably once its window is off screen.
    @ObservationIgnored var onHide: ((ProjectWindowState) -> Void)?
    /// Told when a window is about to close for real, while it is still
    /// listed and its review is already kept for its project. Set by the
    /// app layer, which tidies what it holds for the window and says so in
    /// a window left (`WindowClosing.tidy`).
    @ObservationIgnored var onClose: ((ProjectWindowState) -> Void)?
    /// Told as a window is about to show another project in place, while
    /// it still shows the one it leaves (the project, `nil` for none), with
    /// why. Set by the app layer, which lets go of what the window holds for
    /// that project: its open panels and menus, its rows' approval card,
    /// its panes' decision bars (`WindowProjectSwitch.tidy`). The review
    /// is the registry's (`leaveReview`).
    @ObservationIgnored var onWillSwitchProject: ((ProjectWindowState, UUID?, ProjectSwitchReason) -> Void)?
    /// Told once a window shows another project in place, on what the
    /// project showed last, before the window draws it. Set by the app
    /// layer, which settles the window's layout for it then rather than a
    /// frame later: how the changes panel shares the window, which an open
    /// panel keeps through the switch
    /// (`ProjectWindowState.changesPanelLayout`).
    @ObservationIgnored var onDidSwitchProject: ((ProjectWindowState) -> Void)?
    /// How a switch in place is drawn (`ProjectSwitchHandlers.drawsSwitch`).
    /// Set by the app layer, which owns the drawing: as one change with
    /// nothing animated.
    @ObservationIgnored var drawsSwitch: (_ switching: () -> Void) -> Void = { $0() }

    /// What each window's pane area last reported, kept while the window is
    /// off screen so its panes come back when it does.
    @ObservationIgnored private var reportedPanes: [WindowID: Set<UUID>] = [:]
    /// Windows that are hidden, minimized, or fully covered. Their panes do
    /// not count as visible whatever their pane area reported.
    @ObservationIgnored private var offScreenWindows: Set<WindowID> = []
    /// The main windows in the order they last took the keyboard, the
    /// latest first, as the app layer reports it.
    @ObservationIgnored private(set) var keyOrder: [WindowID] = []

    /// The main window that last took the keyboard. `nil` until one has.
    var lastKeyWindowID: WindowID? {
        keyOrder.first
    }

    /// The main window that is key now, as AppKit reports it
    /// (`windowBecameKey`, `windowResignedKey`); `nil` while another window
    /// (Settings, a sheet, the quick terminal) or no window has the
    /// keyboard. Observed, so the menu's items follow it.
    private(set) var keyWindowID: WindowID?

    /// The window the person was last in, hidden or not, else the primary:
    /// the one that comes back when every window is off screen (a Dock
    /// click, `showLastWindow`; New Window, `openEmptyWindow`).
    var lastUsedWindow: ProjectWindowState {
        lastKeyWindowID.flatMap { window($0) } ?? primary
    }

    /// `primary` is the session's primary selection, which the first
    /// window shows.
    init(
        primary selection: WindowSelection,
        reviewDiscards: ReviewDiscardRecords = ReviewDiscardRecords(),
        worktreePaths: WorktreePathResolver = WorktreePathResolver()
    ) {
        self.reviewDiscards = reviewDiscards
        self.worktreePaths = worktreePaths
        let primary = ProjectWindowState(selection: selection, reviewDiscards: reviewDiscards)
        self.primary = primary
        windows = [primary]
    }

    func window(_ id: WindowID) -> ProjectWindowState? {
        windows.first { $0.id == id }
    }

    /// Records that `id` took the keyboard. Reported by the window's
    /// controller; a hidden window gives it up to whichever window AppKit
    /// makes key next, which reports in turn. A window AppKit brought back
    /// past the registry (the Window menu) is shown again.
    func windowBecameKey(_ id: WindowID) {
        guard let window = window(id) else { return }
        keyWindowID = id
        keyOrder.removeAll { $0 == id }
        keyOrder.insert(id, at: 0)
        setHidden(window, false)
        onKeyWindowChange?(id)
    }

    /// Records that `id` gave the keyboard up. AppKit resigns the old
    /// window first and then makes the new one key, which reports in turn;
    /// only the key window's own resign clears it, so a resign that
    /// arrives late, after another window reported, changes nothing.
    func windowResignedKey(_ id: WindowID) {
        guard keyWindowID == id else { return }
        keyWindowID = nil
    }

    /// Adds a window past the primary, with the selection the session
    /// keeps for it (`WorkspaceSession.addSelection`), which the window's
    /// views read.
    ///
    /// A window already listed comes back as it is, its selection the one
    /// passed: an ID names one selection for its whole life. The session
    /// makes every selection under a new ID (the primary, a project's new
    /// window, a restored window) and `windowID` never changes, so no
    /// second selection can turn up under an ID listed here.
    @discardableResult
    func addWindow(_ selection: WindowSelection) -> ProjectWindowState {
        if let existing = window(selection.windowID) {
            return existing
        }
        let window = ProjectWindowState(selection: selection, reviewDiscards: reviewDiscards)
        windows.append(window)
        return window
    }

    /// Shows `projectID` for the person, the one way every
    /// entry point goes to a project (project ▾, the palette's "#" and
    /// recent projects, a folder opened, a card, ⌘J and the Needs
    /// Attention list, a notification, a menu bar row):
    /// the window that shows it, hidden or not, brought forward; else
    /// `from`, switched to it in place and brought back if hidden or
    /// minimized (`bringOnScreen`). Never a new window, and never a second
    /// one for a project. `from` `nil` is the window commands act on. Which
    /// window shows the project is the session's to decide
    /// (`WorkspaceSession.chooseProject(_:in:)`), as for any selection the
    /// person makes; each window coming to show it takes the review a
    /// window left the project (`raise`, `windowDidSwitchProject`).
    ///
    /// Only the person's choice shows anything. Work behind them, an open
    /// that ends once they have moved on (`intentAfterWait(from:)`), leaves
    /// every window as it is, and so does a `from` that has closed
    /// meanwhile or a project the session does not have. Returns the window
    /// that shows the project, `nil` when nothing was shown.
    @discardableResult
    func show(
        project projectID: UUID,
        in session: WorkspaceSession,
        from: ProjectWindowState?,
        intent: SelectionIntent
    ) -> ProjectWindowState? {
        let from = from ?? backgroundCommandTarget
        guard intent == .person, window(from.id) === from,
              let shown = session.chooseProject(projectID, in: from.id).flatMap({ window($0) })
        else { return nil }
        // The window that already showed the project came forward as it was
        // chosen (`raise`); the one switched in place comes back now, on
        // the project it switched to.
        if shown === from {
            bringOnScreen(from)
        }
        return shown
    }

    /// The window to show what belongs to no project in (a scratch tab, an
    /// approval card, a request no pane is known for): `asked`, else the
    /// window commands act on, brought back if hidden or minimized. It
    /// switches no window and brings no other forward; a card opens over
    /// whatever the window shows.
    @discardableResult
    func bringBack(_ asked: ProjectWindowState?) -> ProjectWindowState {
        let window = asked ?? backgroundCommandTarget
        bringOnScreen(window)
        return window
    }

    /// Shows `window` when the person cannot see it: hidden, or minimized,
    /// which the window commands act on can be, since a minimized window is
    /// not hidden (`backgroundCommandTarget`). Asked from a notification or the menu
    /// bar, a window left in the Dock would show nothing of what was asked;
    /// showing it takes it out of the Dock. A window in front is
    /// left as it is.
    private func bringOnScreen(_ window: ProjectWindowState) {
        if window.isHidden || presenter?.isOnScreen(window.id) == false {
            show(window.id)
        }
    }

    /// The window the person goes to a thing in, a pane or a tab rather
    /// than a project (⌘J, the Needs Attention list, a notification, the
    /// menu bar's rows), shown and in front:
    /// for a thing of a project, where the project is shown
    /// (`show(project:in:from:intent:)`); for one of no project, the window
    /// asked, brought back (`bringBack`). `nil` when nothing can show it.
    func present(project projectID: UUID?, in session: WorkspaceSession, from asked: ProjectWindowState?) -> ProjectWindowState? {
        guard let projectID else { return bringBack(asked) }
        return show(project: projectID, in: session, from: asked, intent: .person)
    }

    /// Has `session` switch windows between projects through this
    /// registry: the window that shows a project the person
    /// chose elsewhere comes forward (`raise`), and a window switching in
    /// place lets go of what it holds for the project it leaves and takes
    /// what the project kept for it (`windowWillSwitchProject`,
    /// `windowDidSwitchProject`). Set by the supervision window's app
    /// layer, before anything can select another project's session.
    func connectProjectSwitching(of session: WorkspaceSession) {
        knownProjects = session.projects
        session.projectSwitching = ProjectSwitchHandlers(
            onRaiseWindow: { [weak self, weak session] id in
                guard let self, let session else { return }
                raise(id, in: session)
            },
            willSwitchProject: { [weak self, weak session] id, from, _, reason in
                guard let self, let session else { return }
                windowWillSwitchProject(id, from: from, reason: reason, in: session)
            },
            didSwitchProject: { [weak self, weak session] id, projectID in
                guard let self, let session else { return }
                windowDidSwitchProject(id, to: projectID, in: session)
            },
            // Listed before it takes its project, so the switch hands it what
            // the project kept (`windowDidSwitchProject`).
            didAddWindow: { [weak self] selection in
                self?.addWindow(selection)
            },
            drawsSwitch: { [weak self] switching in
                guard let self else { return switching() }
                drawsSwitch(switching)
            }
        )
    }

    /// Brings forward the window `id`, shown again if hidden: the one that
    /// shows a project asked for elsewhere. It takes the review a
    /// window left its project, as any window coming to show the
    /// project does (`takeParkedReview`).
    func raise(_ id: WindowID, in session: WorkspaceSession) {
        guard let window = window(id) else { return }
        if let projectID = window.selection.shownProjectID {
            takeParkedReview(of: projectID, into: window, allowsReplacingReview: false, in: session)
        }
        show(id)
    }

    /// `id` is about to leave `from` for another project in place.
    /// The app layer lets go of what the window holds for the project it
    /// leaves (`onWillSwitchProject`), and the review goes with that project
    /// (`leaveReview`).
    ///
    /// The panes of the project left stop counting as drawn and seen: the
    /// window reports what it shows of the next once it has drawn it, and
    /// until then nothing of the project left is taken as seen there, so a
    /// request in it is not handed to a terminal no one looks at.
    /// The panes of a tab in no project (a scratch tab) stay: the window
    /// can be on the same one after the switch, which its view need not
    /// report again, and they would stop drawing on screen.
    func windowWillSwitchProject(_ id: WindowID, from: UUID?, reason: ProjectSwitchReason, in session: WorkspaceSession) {
        guard let window = window(id) else { return }
        onWillSwitchProject?(window, from, reason)
        leaveReview(of: window, for: from, in: session)
        scroll.remember(window, leaving: from, in: session)
        let isInNoProject = { (pane: UUID) in session.tab(containing: pane).map { $0.container.projectID == nil } ?? false }
        reportedPanes[id] = reportedPanes[id]?.filter(isInNoProject)
        attendedByWindow[id] = attendedByWindow[id]?.filter(isInNoProject)
        applyVisibility()
    }

    /// What becomes of `window`'s review as the window leaves `from` for
    /// another project in place. It goes with the project it
    /// reads (`parkReview`), tab and all, whether or not a comment is being
    /// written in it, and comes back as it was once a window shows that
    /// project again: the project keeps its review tab while the window
    /// shows another, as it keeps its sessions. The window then holds no
    /// review of another project, so one opens in the next project as in
    /// any window, and leaves the one kept as it is.
    ///
    /// It waits where its agent's pane is, else for `from`
    /// (`waitingPlace`). A review whose agent's pane is in no project now (a
    /// scratch tab's), or, with the pane gone, one opened from such a pane
    /// (`ReviewTabState.isOfNoProjectNow(in:)`), belongs to no project, and
    /// stays with the window: the scratch tabs go with no project, and the
    /// window can still show them. A scratch tab moved to a project's row
    /// since takes its review to that project, as its strip does: kept
    /// with the window, it could no longer be shown there, and its comment
    /// would refuse every other review. A removed project keeps
    /// nothing, and its review closes. A review with a comment being
    /// written is never closed while its agent's pane is still there: what
    /// cannot be kept for a project stays in the window. The panes the tab
    /// covered are the project's left, so none is woken. The discards stay
    /// where they are, in the store every window shares (`reviewDiscards`).
    private func leaveReview(of window: ProjectWindowState, for from: UUID?, in session: WorkspaceSession) {
        window.reviewOpenRequest = nil
        window.parkedReviewArrival = nil
        let isOfNoProject = window.review?.isOfNoProjectNow(in: session) ?? false
        let agentTab = window.review?.agentPaneID.flatMap { session.tab(containing: $0) }
        let isKept = parkReview(of: window, under: from, kept: isOfNoProject ? .none : .always, in: session)
        guard !isOfNoProject else { return }
        if !isKept, agentTab != nil, window.reviewHasUnsavedComment {
            return
        }
        if window.review != nil {
            window.letGoOfReview()
        }
    }

    /// `id` has switched to `projectID` in place and stands on what the
    /// project showed last, before whatever was asked is selected in it.
    /// It takes the review a window left the project, as a window brought
    /// forward on the project does (`raise`). The switch never closes the
    /// tab it brings back. A switch that carries a target (⌘J, a
    /// notification, a card's item) puts it behind, so the target is on
    /// screen; one with no target (project ▾, ⌘O, going back or forward)
    /// leaves it in front or behind as it was left at the place the window
    /// lands on
    /// (`ProjectWindowState.resolveParkedReviewArrival`). The person's next
    /// move follows the usual rule. The app layer lays the window out for
    /// the project then, before the window draws it (`onDidSwitchProject`).
    func windowDidSwitchProject(_ id: WindowID, to projectID: UUID?, in session: WorkspaceSession) {
        guard let window = window(id) else { return }
        // Laid out first: which lists are on screen as the window lands,
        // and so take back their places, depends on whether the panel
        // folds the sidebar as the window lands.
        onDidSwitchProject?(window)
        scroll.bringBack(projectID, to: window)
        guard let projectID else { return }
        guard takeParkedReview(of: projectID, into: window, allowsReplacingReview: true, in: session) != .notTaken else { return }
        window.parkedReviewArrival = .pending(left: ReviewArrival(window.selection))
        // Resolved once the switch is done, with whatever row or tab was
        // asked for with it selected; a view looking first resolves it the
        // same way (`isParkedReviewArrival`).
        Task { @MainActor [weak window] in
            window?.resolveParkedReviewArrival()
        }
    }

    /// Lists the windows of a restored session, one for each of its
    /// selections, the hidden ones hidden, before anything can ask for a
    /// project's window: a window the registry did not list could not be
    /// brought forward as its project is chosen elsewhere (`raise`). Called
    /// as the windows are handed to the app, ahead of `showRestoredWindows`.
    func adoptWindows(of session: WorkspaceSession) {
        for id in session.windowIDs {
            guard let selection = session.selection(id) else { continue }
            setHidden(addWindow(selection), session.hiddenWindowIDs.contains(id))
        }
    }

    /// Shows the windows `adoptWindows` listed that were shown at quit, the
    /// one the person was last in shown last so it is in front. With none
    /// shown, the session holds the one window hidden as every window
    /// closed (`WindowRecord.normalized`), the primary, and it is shown, as
    /// the Dock would bring it back. Until a window takes the keyboard, the
    /// one in front counts as last used, so what arrives meanwhile (a folder
    /// opened at launch) acts in it, not in the primary (`backgroundCommandTarget`).
    func showRestoredWindows(of session: WorkspaceSession) {
        let front = session.frontWindowID
        let shown = windows.map(\.id).filter { !session.hiddenWindowIDs.contains($0) }
        guard !shown.isEmpty else {
            show(primary.id)
            return
        }
        let ordered = shown.filter { $0 != front } + shown.filter { $0 == front }
        for id in ordered {
            show(id)
        }
        if let last = ordered.last {
            keyOrder = keyOrder.isEmpty ? [last] : keyOrder
            presenter?.raiseAfterFullScreenEntries(last)
        }
    }

    /// Shows a window, through the presenter when the app owns its windows.
    func show(_ id: WindowID) {
        guard let window = window(id) else { return }
        setHidden(window, false)
        presenter?.show(window, openedFrom: nil)
    }

    /// The one place a window's hidden state changes, so the session hears
    /// of each change once (`onVisibilityChange`).
    private func setHidden(_ window: ProjectWindowState, _ isHidden: Bool) {
        guard window.isHidden != isHidden else { return }
        window.isHidden = isHidden
        onVisibilityChange?(window.id, isHidden)
    }

    /// The answer to a Dock click with no window on screen: the window the
    /// person was last in, else the primary, brought back as it was. Never
    /// a new window beside the hidden ones.
    func showLastWindow() {
        guard let presenter, !windows.contains(where: { presenter.isOnScreen($0.id) }) else { return }
        show(lastUsedWindow.id)
    }

    /// Hides a window rather than closing it, so its agents keep running and
    /// its sessions come back as they were. Its review tab does not, unless a
    /// comment is being written in it (`onHide`). What the last shown
    /// window comes to as it closes (`close`).
    func hide(_ id: WindowID) {
        guard let window = window(id) else { return }
        // Told once per hiding; the window goes from the screen whatever
        // the flag says, since AppKit may have brought it back past us.
        let wasHidden = window.isHidden
        setHidden(window, true)
        // Off screen, it has no keyboard, whether or not AppKit has said so
        // yet; a command must not act in it meanwhile.
        windowResignedKey(id)
        if !wasHidden {
            log.notice("""
            window \(id.rawValue.uuidString, privacy: .public) hidden, \
            project \(window.selection.shownProjectID?.uuidString ?? "none", privacy: .private)
            """)
            onHide?(window)
        }
        presenter?.hide(id)
    }

    /// Closes a window: the close button, ⇧⌘W, the Window menu. While
    /// another window is shown, minimized
    /// ones included (`isHidden`, never what is on screen), the window
    /// ends: its project keeps what it showed (`WorkspaceSession.removeWindow`)
    /// and its review (`parkedReviews`), a scratch pane's waiting for the
    /// scratch row instead (`parkedScratchReview`), and the primary's role
    /// goes to a window left. The last window shown is hidden instead, so
    /// the Dock brings it back where it was and in full screen; a window
    /// hidden before it ends then, so at most one window is ever hidden.
    /// Either way the sessions and agents keep running.
    func close(_ id: WindowID, in session: WorkspaceSession) {
        guard let window = window(id) else { return }
        guard windows.contains(where: { $0.id != id && !$0.isHidden }) else {
            for earlier in windows where earlier.id != id && earlier.isHidden {
                end(earlier, in: session)
            }
            hide(id)
            return
        }
        end(window, in: session)
    }

    /// Hands the primary's role to `id`: the registry's and the
    /// session's together, the one place either changes.
    func makePrimary(_ id: WindowID, in session: WorkspaceSession) {
        guard let window = window(id), window !== primary else { return }
        session.makePrimary(id)
        primary = window
        windows.removeAll { $0 === window }
        windows.insert(window, at: 0)
    }

    /// Ends `window`: what it showed is kept for its project, the app
    /// layer tidies what it holds for it (`onClose`), and nothing it
    /// reported counts any longer. A report it sends as it goes is not
    /// heard (`didReportVisibility`). The only window is never ended.
    private func end(_ window: ProjectWindowState, in session: WorkspaceSession) {
        let id = window.id
        if window === primary, let heir = windowShown(besides: id) ?? windows.first(where: { $0.id != id }) {
            makePrimary(heir.id, in: session)
        }
        guard window !== primary else { return }
        parkReview(of: window, under: window.selection.shownProjectID, kept: .withComment, in: session)
        // Its project keeps where its lists were, as it keeps what it showed:
        // a window switching to it brings them back.
        scroll.remember(window, leaving: window.selection.shownProjectID, in: session)
        onClose?(window)
        window.markClosed()
        windows.removeAll { $0.id == id }
        keyOrder.removeAll { $0 == id }
        windowResignedKey(id)
        reportedPanes[id] = nil
        attendedByWindow[id] = nil
        offScreenWindows.remove(id)
        applyVisibility()
        log.notice("""
        window \(id.rawValue.uuidString, privacy: .public) closed, \
        project \(window.selection.shownProjectID?.uuidString ?? "none", privacy: .private)
        """)
        session.removeWindow(id)
        presenter?.close(id)
        // What the closed window still holds of its review is its project's
        // now, or gone: nothing that outlives the window for a moment (a
        // toast's Undo, a task) keeps the review open through it.
        window.letGoOfReview()
    }

    /// Keeps `window`'s review as the window closes, or as it leaves its
    /// project: its tab, where it waits (`waitingPlace`). A
    /// window switching in place keeps its tab for the project (`kept`);
    /// one closing keeps it only with a comment being written in it, and
    /// closes it otherwise. The scratch row keeps a tab only with a
    /// comment: nothing else of it would be missed there. `projectID`, the
    /// project the window shows or leaves, is where a project's review
    /// waits once its agent's pane is gone. The discards are not the
    /// window's to hand on: they stay in the store every window shares
    /// (`reviewDiscards`). An open on its way lands nowhere. A project the
    /// session no longer has keeps nothing. Says whether a tab is kept.
    ///
    /// The tabs kept there already, from an earlier window, join this one;
    /// none with a comment is dropped for it (`ParkedReview.tabs(_:joining:)`).
    /// Two comments meet in a project when windows leave reviews whose
    /// agents' panes are on its rows while the windows show another project
    /// or none: as they close, or as a window switches away from a project
    /// with a review of an agent on another project's row.
    @discardableResult
    private func parkReview(
        of window: ProjectWindowState,
        under projectID: UUID?,
        kept: ParkedReview.TabKept,
        in session: WorkspaceSession
    ) -> Bool {
        window.reviewOpenRequest = nil
        guard let review = window.review else { return false }
        switch waitingPlace(of: review, owner: projectID, in: session) {
        case nil:
            return false
        case .scratchRow:
            guard kept != .none, let left = ParkedReview.Tab(leftBy: window, kept: .withComment) else { return false }
            park(left, at: .scratchRow, leaving: window, in: session)
            return true
        case let .project(id):
            guard let left = ParkedReview.Tab(leftBy: window, kept: kept) else { return parkedReviews[id] != nil }
            park(left, at: .project(id), leaving: window, in: session)
            return true
        }
    }

    /// Where a review a window lets go of waits until a window takes it.
    private enum WaitingPlace: Equatable {
        /// For the project, as its sessions wait (`parkedReviews`).
        case project(UUID)
        /// For the scratch row (`parkedScratchReview`).
        case scratchRow
    }

    /// Where `review` waits: by the row its agent's pane is on now, the
    /// rule its tab is shown in a strip by (`ReviewTabState.belongs`), a
    /// project's row for that project, the scratch row for the scratch
    /// row. With the pane gone, the owner it was opened with decides
    /// (`ReviewTabState.isOfNoProject`): a scratch pane's waits for the
    /// scratch row, a project's for `owner`, the project the window showed
    /// or left, or for the scratch row when the window showed none. `nil`
    /// for a project the session no longer has: it keeps nothing.
    private func waitingPlace(of review: ReviewTabState, owner: UUID?, in session: WorkspaceSession) -> WaitingPlace? {
        let row = review.agentPaneID.flatMap { session.tab(containing: $0)?.container }
        let projectID = row.map(\.projectID) ?? (review.isOfNoProject ? nil : owner)
        guard let projectID else { return .scratchRow }
        return session.project(projectID) != nil ? .project(projectID) : nil
    }

    /// Keeps `tab` at `place`, beside the tabs kept there already
    /// (`ParkedReview.tabs(_:joining:)`), so no comment is dropped for it.
    /// A window already standing where the tab belongs, the agent's row or
    /// the scratch row, takes it at once, as it would arriving there, but
    /// only one holding no review at all and opening none: a review the
    /// person left there, even behind, is theirs, and is never swapped for
    /// another, and one they asked for is not refused for this tab's
    /// comment. The window that draws the scratch tabs is asked first, then
    /// any other shown window; never `leaving`, the window the tab comes
    /// from, which may still be listed, and draw the scratch tabs, as it
    /// closes. The tabs kept already go where they wait now first
    /// (`rehomeParkedReviews`), so none joins this one where it no longer
    /// belongs.
    private func park(_ tab: ParkedReview.Tab, at place: WaitingPlace, leaving: ProjectWindowState?, in session: WorkspaceSession) {
        rehomeParkedReviews(leaving: leaving, in: session)
        keep(tab, at: place, isMoved: false, leaving: leaving, in: session)
    }

    /// `park`, with the tabs kept already taken as they stand. A tab
    /// `isMoved` from another place joins behind those kept here
    /// (`ParkedReview.tabs(_:joinedBy:)`). Each window standing on a
    /// project's row is handed the tab whose agent is on that row
    /// (`ParkedReview.index(onRow:in:)`), whichever tab is first.
    private func keep(
        _ tab: ParkedReview.Tab,
        at place: WaitingPlace,
        isMoved: Bool,
        leaving: ProjectWindowState?,
        in session: WorkspaceSession
    ) {
        let drawer = session.scratchDrawingWindowID.flatMap { window($0) }
        let standing = ([drawer].compactMap(\.self) + windows).filter {
            $0 !== leaving && !$0.isHidden && !$0.isClosed && $0.review == nil && $0.reviewOpenRequest == nil
        }
        let joined = { (existing: [ParkedReview.Tab]) in
            ParkedReview(tabs: isMoved ? ParkedReview.tabs(existing, joinedBy: tab) : ParkedReview.tabs(tab, joining: existing))
        }
        switch place {
        case let .project(projectID):
            parkedReviews[projectID] = joined(parkedReviews[projectID]?.tabs ?? [])
            for heir in standing {
                guard let parked = parkedReviews[projectID],
                      let index = parked.index(onRow: heir.selection.activeContainerID, in: session)
                else { continue }
                parkedReviews[projectID] = parked.opening(at: index, in: heir)
            }
        case .scratchRow:
            parkedScratchReview = joined(parkedScratchReview?.tabs ?? [])
            if let heir = standing.first(where: { $0.selection.activeContainerID.projectID == nil }) {
                parkedScratchReview = parkedScratchReview?.opening(in: heir)
            }
        }
    }

    /// Moves each tab kept to where it waits now (`waitingPlace`), with the
    /// place it was kept at as its owner: its agent's tab may have been
    /// dragged to another row since, the scratch row or another project's,
    /// and a window takes a tab only where its strip can show it, or
    /// the tab's comment would refuse every other review there. A tab whose
    /// pane is gone stays where it was kept, the last row it was known on,
    /// while that project is there. A project the session no longer has
    /// keeps nothing, and the scratch row takes only a tab with a comment
    /// being written in it, as `parkReview` leaves it there; any other tab
    /// that has to move is let go of. A moved tab joins behind those kept
    /// where it goes, the places sorted out in an order of their own, so
    /// the same tabs always end the same way. A window standing where a
    /// moved tab belongs takes it as `keep` hands it on, never `leaving`,
    /// the window a tab is being kept from or taken into. Called before a
    /// tab is kept or taken, and as projects go (`forgetProjectsGone`).
    private func rehomeParkedReviews(leaving: ProjectWindowState?, in session: WorkspaceSession) {
        var moving: [(tab: ParkedReview.Tab, place: WaitingPlace?)] = []
        func sortOut(_ tabs: [ParkedReview.Tab], keptAt here: WaitingPlace, owner: UUID?) -> [ParkedReview.Tab] {
            let placed = tabs.map { tab in
                let isPaneGone = tab.review.agentPaneID.flatMap { session.tab(containing: $0) } == nil
                let isStillThere = owner.map { session.project($0) != nil } ?? true
                return (tab: tab, place: isPaneGone && isStillThere ? here : waitingPlace(of: tab.review, owner: owner, in: session))
            }
            moving += placed.filter { $0.place != here }
            return placed.filter { $0.place == here }.map(\.tab)
        }
        for projectID in parkedReviews.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let staying = sortOut(parkedReviews[projectID]?.tabs ?? [], keptAt: .project(projectID), owner: projectID)
            parkedReviews[projectID] = staying.isEmpty ? nil : ParkedReview(tabs: staying)
        }
        if let scratch = parkedScratchReview {
            let staying = sortOut(scratch.tabs, keptAt: .scratchRow, owner: nil)
            parkedScratchReview = staying.isEmpty ? nil : ParkedReview(tabs: staying)
        }
        for (tab, place) in moving {
            guard let place, place != .scratchRow || (tab.session?.holdsComment ?? false) else { continue }
            keep(tab, at: place, isMoved: true, leaving: leaving, in: session)
        }
    }

    /// Whether `window`, arriving at the scratch row, takes a tab waiting
    /// there: not let go of, and holding no review of its own but a
    /// scratch pane's behind with nothing being written in it, which the
    /// move would have closed had the window been on a project's row. A
    /// review in front, or one of a project, is the person's, and stays.
    /// Whose it is goes by the row its agent's pane is on now
    /// (`ReviewTabState.isOfNoProjectNow(in:)`): a scratch tab moved to a
    /// project's row is that project's, and the switch that brought it
    /// back never closes it.
    private static func takesParkedScratchReview(arriving window: ProjectWindowState, in session: WorkspaceSession) -> Bool {
        guard !window.isClosed, !window.isHidden, window.selection.activeContainerID.projectID == nil else { return false }
        guard let review = window.review else { return true }
        return review.isOfNoProjectNow(in: session) && !review.isShown && !window.reviewHasUnsavedComment
    }

    /// `window` arrives at a row (`ReviewTabActions.rowChanged`) and takes,
    /// behind, a tab waiting for it there: at the scratch row the
    /// first tab waiting there, when it can (`takesParkedScratchReview`);
    /// at a project's row, holding no review and opening none, the first
    /// tab its project keeps whose agent is on that row, as a window
    /// standing there takes one as it is kept (`keep`). Decided here as the
    /// window arrives, not by which of the moves that brought the tab there
    /// was heard first.
    func takeParkedReview(arrivingAt window: ProjectWindowState, in session: WorkspaceSession) {
        rehomeParkedReviews(leaving: window, in: session)
        let row = window.selection.activeContainerID
        guard let projectID = row.projectID else {
            guard parkedScratchReview?.tab != nil, Self.takesParkedScratchReview(arriving: window, in: session) else { return }
            parkedScratchReview = parkedScratchReview?.opening(in: window)
            return
        }
        guard !window.isClosed, !window.isHidden, window.review == nil, window.reviewOpenRequest == nil,
              let index = parkedReviews[projectID]?.index(onRow: row, in: session)
        else { return }
        parkedReviews[projectID] = parkedReviews[projectID]?.opening(at: index, in: window)
    }

    /// What became of a review tab a project kept as a window came to show
    /// the project (`takeParkedReview`).
    enum ParkedTabTaken: Equatable {
        case inFront
        case behind
        /// No tab was taken: none was kept, or the window keeps its own.
        case notTaken
    }

    /// Gives `window`, which has just come to show `projectID`, the review
    /// a window left the project as it closed or switched (`parkReview`):
    /// its tab opens as it was left
    /// (`ParkedReview.Tab.open`), with the comment its review holds. In
    /// front only where it was, and where the window stands on the session
    /// it belongs to: on another row the strip has no place for it, and it
    /// waits behind, as it would have had the window stayed
    /// (`ReviewTabState.belongs`). Says where the tab came, if it did.
    ///
    /// A project has one review tab. A window that arrives holding a
    /// review of its own, a scratch pane's (which goes with no project),
    /// lets it go for the project's tab when `allowsReplacingReview` and
    /// nothing is being written in it; its discards stay in the store every window
    /// shares (`reviewDiscards`). With a comment being
    /// written there, the window keeps it, and the project's tab and what
    /// came with it stay kept for the project, rather than drop one of the
    /// two comments; opening a review in the project brings the tab
    /// (`takeParkedReviewBeforeOpening`). A window brought forward on the
    /// project (`raise`) keeps what it holds. Of tabs that met in the
    /// project (`parkReview`), the window takes the first; the others stay
    /// kept for the project. No discard moves with a tab: the records are
    /// the worktree's, in the one store every window shares
    /// (`reviewDiscards`), whoever holds the tab.
    @discardableResult
    private func takeParkedReview(
        of projectID: UUID,
        into window: ProjectWindowState,
        allowsReplacingReview: Bool,
        in session: WorkspaceSession
    ) -> ParkedTabTaken {
        rehomeParkedReviews(leaving: window, in: session)
        guard let parked = parkedReviews[projectID] else { return .notTaken }
        if parked.tab != nil, window.review != nil {
            guard allowsReplacingReview, !window.reviewHasUnsavedComment else { return .notTaken }
            window.letGoOfReview()
        }
        guard let tab = parked.tab else { return .notTaken }
        let rest = Array(parked.tabs.dropFirst())
        parkedReviews[projectID] = rest.isEmpty ? nil : ParkedReview(tabs: rest)
        let isShown = tab.review.isShown && tab.review.belongs(to: window.selection.activeContainerID, in: session)
        tab.open(in: window, isShown: isShown)
        return isShown ? .inFront : .behind
    }

    /// Before a review opens in `window`: a project has one review tab,
    /// so the one its project keeps, while the window stands on one of the
    /// project's rows, takes the place of whatever the window has open, and
    /// the open then reads in it as in any open tab. A comment being written
    /// there refuses another reading, as it would have had the window
    /// stayed; the tab is brought behind, so the open decides what comes to
    /// front. A review of the window's own with a comment being written
    /// stays: the open is refused for that comment, and the project's tab
    /// stays kept. On a scratch tab the project's tab stays kept too: what
    /// opens there is no project's; the first tab waiting for the scratch
    /// row (`parkedScratchReview`) comes instead, the same way.
    func takeParkedReviewBeforeOpening(into window: ProjectWindowState, in session: WorkspaceSession) {
        guard !window.reviewHasUnsavedComment else { return }
        rehomeParkedReviews(leaving: window, in: session)
        if window.selection.activeContainerID.projectID == nil {
            parkedScratchReview = parkedScratchReview?.opening(in: window)
            return
        }
        guard let projectID = window.selection.shownProjectID,
              window.selection.activeContainerID.projectID == projectID,
              parkedReviews[projectID]?.tab != nil
        else { return }
        takeParkedReview(of: projectID, into: window, allowsReplacingReview: true, in: session)
        window.review?.isShown = false
    }

    /// Lets go of what the windows keep for projects the session no longer
    /// has: the reviews kept for them, as a removed project's review
    /// never comes back and its open review would hold its turns from the
    /// sweep until the app quits (`ReviewDraftWriterPool.openTurnRanges`);
    /// where their lists were scrolled (`scrollMemories`); and a new
    /// session sheet open for one in any window, whose session would have
    /// no project to be made in; and, as a project is removed,
    /// its worktrees' discards (`forgetDiscards`). Called by the app layer
    /// as the projects change, which they do as a tab is chosen too: the
    /// tabs kept then go where their agents' panes are now, for projects
    /// still there too (`rehomeParkedReviews`), and one with nothing written
    /// in it that would wait for the scratch row is let go of. Otherwise
    /// only a project the session no longer has lets go of anything.
    func forgetProjectsGone(in session: WorkspaceSession) {
        let removed = knownProjects.filter { session.project($0.id) == nil }
        knownProjects = session.projects
        for window in windows {
            if let projectID = window.newSession?.projectID, session.project(projectID) == nil {
                window.newWorktreeSheet.close()
            }
        }
        // Every tab kept waits where its agent's pane is now, the scratch
        // row only with a comment. With the pane gone, a tab stays where it
        // was kept; once that project is removed too, a scratch pane's
        // waits for the scratch row its owner is, and a project's goes with
        // the project.
        rehomeParkedReviews(leaving: nil, in: session)
        // A removed project's positions go with its view.
        scroll.forget { session.project($0) == nil }
        if !removed.isEmpty {
            forgetDiscards(of: removed, in: session)
        }
    }

    /// Records which panes `window`'s pane area draws. A pane's terminal
    /// keeps rendering while any on-screen window reports it. Leaves what the
    /// person sees alone; that comes only with `didReportDisplay`.
    ///
    /// A window the registry does not list is not heard: a view can report
    /// once more as it goes, after its window has gone, and its panes
    /// would then count as drawn and seen with no window to show them.
    func didReportVisibility(window: WindowID, paneIDs: Set<UUID>) {
        guard self.window(window) != nil else { return }
        reportedPanes[window] = paneIDs
        applyVisibility()
    }

    /// Records what `window`'s pane area shows: the panes that draw, and the
    /// ones the person can be said to see. Not from a window the registry
    /// does not list (`didReportVisibility`).
    func didReportDisplay(window: WindowID, rendered: Set<UUID>, attended: Set<UUID>) {
        guard self.window(window) != nil else { return }
        attendedByWindow[window] = attended
        didReportVisibility(window: window, paneIDs: rendered)
    }

    /// Whether Weir is the frontmost app. Set by the app layer, which
    /// reads it from AppKit.
    func appActivityChanged(isActive: Bool) {
        // Assigned only on change, so whoever watches `attention` is not
        // woken for nothing.
        if attention.isAppActive != isActive {
            attention.isAppActive = isActive
        }
    }

    /// Whether VoiceOver is running. Set by the app layer.
    func voiceOverChanged(isRunning: Bool) {
        if attention.isVoiceOverRunning != isRunning {
            attention.isVoiceOverRunning = isRunning
        }
    }

    /// Records whether `window` can be seen at all. Reported by the
    /// window's occlusion observer, after AppKit has settled the change, so
    /// a window that is closing is not still counted as on screen. Not from
    /// a window the registry does not list (`didReportVisibility`).
    func windowScreenPresenceChanged(_ window: WindowID, isOnScreen: Bool) {
        guard self.window(window) != nil else { return }
        if isOnScreen {
            offScreenWindows.remove(window)
        } else {
            offScreenWindows.insert(window)
        }
        applyVisibility()
    }

    private func applyVisibility() {
        var next = PaneVisibility()
        for (window, panes) in reportedPanes where !offScreenWindows.contains(window) {
            next.report(window: window, visiblePaneIDs: panes)
        }
        visibility = next
        let attended = attendedByWindow
            .filter { !offScreenWindows.contains($0.key) }
            .values
            .reduce(into: Set<UUID>()) { $0.formUnion($1) }
        if attention.attendedPanes != attended {
            attention.attendedPanes = attended
        }
        occlusion?.updateOcclusion(visibleIDs: next.union)
    }

    // MARK: - Decision bars

    /// The epoch `paneID` is in (`PaneRunLedger.epoch(inPane:)`). A bar
    /// reads it only in its change handlers, never in `body`, so the ledger
    /// is not observed and a pass that notes runs draws nothing again.
    func epoch(inPane paneID: UUID) -> Int? {
        paneRuns.epoch(inPane: paneID)
    }

    /// Notes this pass's runs, ends the "Done" lines of the panes the runs
    /// moved on in (`PaneRunLedger.note`, with the panes whose stop ended
    /// as the person moved on there), then gives each stop that came back
    /// in this pass its "Resumed" line. The lines end first because the
    /// resumed conversation's new run is itself a change in its pane, and
    /// would otherwise end the line that announces it. Kept once for every
    /// window, as the runs are the app's, so a window opened later is
    /// compared from the same pass as the others.
    ///
    /// The "Resumed" line is left pending: the conversation's unread turns
    /// come back with it, and a line set now would be cleared by them before
    /// the bar takes it (`DecisionBarContent.takes`). It is not set for a
    /// run that already began a turn, which the line's "Type your next
    /// instruction" would be late for.
    func noteRuns(_ runs: [PaneRunLedger.Run], endedStops: StopLedger.Ended = StopLedger.Ended()) {
        runsChanged(inPanes: paneRuns.note(runs, movedOnFromStops: endedStops.movedOn))
        for back in endedStops.resumed where !back.hasBegunATurn {
            guard let shown = back.window.flatMap({ self.window($0) }) else { continue }
            shown.pendingDecisionBarDone[back.paneID] = .resumed
        }
    }

    /// A turn began in `panes`, or the agent left them: every window ends
    /// their "Done" lines (`ProjectWindowState.runsChanged`). A pane is shown
    /// in one window at a time, but which one can change as windows switch
    /// projects, so every window is told.
    private func runsChanged(inPanes panes: Set<UUID>) {
        guard !panes.isEmpty else { return }
        for window in windows {
            window.runsChanged(inPanes: panes)
        }
    }
}
