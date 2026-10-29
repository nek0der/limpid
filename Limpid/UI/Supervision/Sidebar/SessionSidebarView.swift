// SessionSidebarView.swift
// Limpid — the supervision window's sidebar: every project under its header, its rows, and the scratch row.

import AppKit
import SwiftUI

/// The sidebar: the heading, then every project under its own header
/// in the window's order, each open header with its rows in the two-line
/// form, and the scratch row at the bottom. Each row opens its session; its
/// right-click menu holds the worktree operations (`SessionRowActions`). A
/// header opens or folds, and its menu moves the project
/// (`SidebarProjectActions`).
struct SessionSidebarView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(AttentionState.self) private var attention
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(PRStatusStore.self) private var prStatusStore
    @Environment(GitFactsStore.self) private var gitFacts
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(LimpidDragState.self) private var dragState
    @Environment(\.prStatusSyncer) private var prStatusSyncer
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.agentProjection) private var agentProjection
    @Environment(\.frecencyStore) private var frecencyStore
    @Environment(\.locale) private var locale
    @Environment(UsageLimitResetSync.self) private var resetSync: UsageLimitResetSync?
    @State private var renamingRow: ContainerID?
    @State private var deletingWorktree: DeleteWorktreeTarget?
    @State private var deletingWorktrees: DeleteWorktreesTarget?
    @State private var forceDeleteWorktree: ForceDeleteWorktreeTarget?
    @State private var worktreeOperationError: DisplayText?
    /// Whether the sidebar has the keyboard (⌥⌘0).
    @FocusState private var isFocused: Bool
    /// While ⌥⌘0 lasts, the sidebar can take the keyboard; otherwise a
    /// click on a row must not take it from the terminal.
    @State private var isKeyboardActive = false
    /// This is true when the keys pressed are the sidebar's own, which they
    /// are not while a row's name is being edited. The name field is inside
    /// the sidebar, so its keys reach the sidebar's handlers too, and
    /// `isFocused` does not tell them apart; when the handlers took them,
    /// Return never submitted the name and ← → never moved in it.
    private var ownsKeys: Bool {
        isFocused && renamingRow == nil
    }

    /// The line the arrow keys are on while the sidebar has the keyboard:
    /// a header, a fold line, or a row.
    @State private var keyboardLine: SidebarItemID?
    /// The line to bring into view next, as a header moves.
    @State private var scrollRequest: ScrollRequest?

    var body: some View {
        // Read once for every project, rather than once per header and row.
        let others = session.otherWindowsByProject(than: window.id)
        let sections = presentedSections(others: others)
        let model = SidebarListModel(
            session: session,
            window: window.id,
            sections: sections,
            windowShowing: { others[$0] },
            sources: SidebarListModel.Sources(
                queue: attentionQueue.queue,
                runtimes: attention.allRuntimes,
                approvals: approvals.ledger,
                pullRequest: { prStatusStore.info(for: $0) },
                gitFacts: { gitFacts.facts(for: $0) },
                running: { attention.runningAgentCount(inProject: $0, session: session) },
                locale: locale
            ),
            // While a header is dragged, every project is drawn folded, so
            // the headers stand together to be dropped among.
            isDraggingProject: dragState.current == .project
        )
        VStack(alignment: .leading, spacing: 0) {
            SurfaceHeadingLine {
                Text(ProjectListText.heading)
            } trailing: {
                // A folder opened as a project, as ⌘O does; a header's ＋
                // makes a new worktree in its own.
                Button {
                    SupervisionWindowActions.openFolder(
                        from: window,
                        session: session,
                        registry: windowRegistry,
                        frecency: frecencyStore
                    )
                } label: {
                    Image(systemName: "plus")
                        .font(.supervision(.icon, weight: .medium))
                        .frame(height: LimpidLayout.Supervision.sidebarHeadingButtonHeight)
                }
                .buttonStyle(.supervisionIcon)
                // Out of ⇥'s stops with the rest of the sidebar; ⌘O is its
                // key, and VoiceOver reaches it as a button.
                .focusable(false)
                // The tooltip names the action as the File menu and
                // project ▾ do, ellipsis included: the button opens the
                // same panel.
                .help(Text(verbatim: ShortcutHelpText.make(
                    name: LimpidShortcutAction.openFolder.localizedTitle,
                    shortcut: settings.settings.keyboard.shortcut(for: .openFolder)?.displayString,
                    locale: locale
                )))
                .accessibilityLabel(Text(ProjectListText.openFolderLabel))
            }
            // With no project there is nothing to list: the empty state
            // takes the list's place and the room down to the scratch row,
            // centered in it, with the way to add a project. Drawn in place
            // of the scroll view rather than inside its lazy stack, where
            // its height had to come from `containerRelativeFrame` and a
            // window with no project showed a blank instead.
            if let emptyState = model.emptyState {
                SupervisionEmptyState(emptyState, size: .regular) {
                    OpenFolderButton()
                }
                // No line is in sight while there is no list.
                .onAppear { window.sidebarVisibleLines = [] }
            } else {
                projectList(model, others: others)
            }
            // The sidebar's foot bar, its rule from edge to edge of the
            // surface under the list it closes.
            SidebarFootBar {
                ScratchRowView(
                    isActive: model.isScratchActive,
                    isKeyboardSelected: isFocused && keyboardLine == .row(.loose),
                    actions: scratchActions
                ) {
                    session.setActiveContainer(.loose, in: window.id, intent: .person)
                }
                .modifier(SessionRowDropTarget(container: .loose, project: nil, acceptsTabs: true, session: session))
            }
        }
        // What the sidebar drew is what a hold keeps, and what ⌃⌘1…9 counts.
        .onChange(of: sections, initial: true) { _, sections in
            window.present(sections)
        }
        // A project the window has not met is met where it is listed, at
        // the bottom, folded or not by the default rule once and for all,
        // so its header never opens or folds later by itself.
        .onChange(of: session.projects.map(\.id), initial: true) {
            settleArrangement(sections: sections, others: others)
        }
        // A line the keys were on that went from the list (a header folded
        // around it, a section folded, a project closed, every header
        // drawn folded for a drag): the keys go to its project's header,
        // else nowhere.
        .onChange(of: model.items.map(\.id)) { _, lines in
            guard let line = keyboardLine, line != .row(.loose), !lines.contains(line) else { return }
            keyboardLine = line.projectID.map(SidebarItemID.header).flatMap { lines.contains($0) ? $0 : nil }
        }
        // The pointer over the sidebar holds the rows' sections.
        .onHover { window.isPointerInSidebar = $0 }
        // A sidebar hidden under the pointer reports no exit; it holds
        // nothing once it is gone.
        .onDisappear {
            window.isPointerInSidebar = false
            window.isSidebarKeyboardActive = false
            // The list drawn again starts at its top: nothing of this one
            // is in sight then.
            window.sidebarVisibleLines = []
        }
        .focusable(isKeyboardActive)
        .focusEffectDisabled()
        .focused($isFocused)
        // Move Project Up and Down (⌥⌘↑ ⌥⌘↓ by default) move a project while
        // the sidebar has the keyboard, ahead of the pane menu, which holds
        // the same keys by default (`SidebarKeyRoute`). Set only then, so
        // the keys are the menu's everywhere else.
        .background {
            if isFocused {
                WindowKeyDownMonitor { event, nsWindow in
                    handleMonitoredKey(event, in: nsWindow)
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        // ⌥⌘0: the keyboard comes here, on the row that is open, or on
        // its project's header while that is folded. A request made while
        // the sidebar was hidden is picked up as it appears, and each is
        // taken once.
        .onChange(of: window.sidebarFocusRequest, initial: true) { _, request in
            guard request != nil else { return }
            window.sidebarFocusRequest = nil
            isKeyboardActive = true
            keyboardLine = initialKeyboardLine(in: model)
            // Once the sidebar is focusable and the terminal has let go.
            KeyboardHandoff.afterResponderSettles { isFocused = true }
        }
        .onChange(of: isFocused) { _, isFocused in
            // The keyboard in the sidebar holds the rows' sections too.
            window.isSidebarKeyboardActive = isFocused
            if !isFocused {
                isKeyboardActive = false
                keyboardLine = nil
            }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return], phases: [.down, .repeat]) { press in
            handleKey(press, in: model)
        }
        .onKeyPress(.escape) {
            guard ownsKeys else { return .ignored }
            returnKeyboardToTerminal()
            return .handled
        }
        .worktreeOperationAlerts(
            deletingWorktree: $deletingWorktree,
            deletingWorktrees: $deletingWorktrees,
            forceDeleteWorktree: $forceDeleteWorktree,
            // A header's Close Project… is confirmed by the title bar's
            // host, as the project ▾'s is.
            removingProject: .constant(nil),
            worktreeOperationError: $worktreeOperationError
        )
    }

    /// One line of the list: a header, with the gap that sets it apart
    /// from the project before; a fold line; or a row.
    @ViewBuilder
    private func line(_ item: SidebarListModel.Item, in model: SidebarListModel, others: [UUID: WindowID], now: Date) -> some View {
        switch item {
        case let .header(header):
            headerView(header, in: model, others: others)
                .padding(.top, model.groups.first?.id == header.id ? 0 : LimpidLayout.Supervision.sidebarProjectGap)
        case let .fold(fold):
            SidebarSectionFoldRow(
                fold: fold,
                isKeyboardSelected: isFocused && keyboardLine == item.id,
                clear: foldClear(fold)
            ) { setFold(fold.section, of: fold.projectID, isOpen: !fold.isOpen) }
        case let .row(row):
            sessionRow(row, in: row.id.projectID.flatMap { session.project($0) }, others: others, now: now)
        }
    }

    private func headerView(_ header: SidebarProjectHeader, in model: SidebarListModel, others: [UUID: WindowID]) -> some View {
        let order = model.headers.map(\.id)
        return SidebarProjectHeaderView(
            header: header,
            isKeyboardSelected: isFocused && keyboardLine == .header(header.id),
            actions: headerActions(header, order: order, others: others),
            onToggle: { isAll in
                if isAll {
                    setAllCollapsed(!header.isCollapsed)
                } else {
                    setCollapsed(!header.isCollapsed, header.id)
                }
            },
            drag: SidebarProjectHeaderView.Drag(
                dragState: dragState,
                isNoOp: { source, position in
                    ProjectOrder.dropped(source, on: header.id, isAfter: position == .after, in: order) == order
                },
                onDrop: { source, position in
                    arrange { $0.drop(source, on: header.id, isAfter: position == .after, among: projectIDs) }
                }
            )
        )
        // A folded project's requests have no row to stand beside: the
        // approval card opened for one stands beside its header.
        .modifier(ApprovalRowAnchor(requests: header.requestKeys.compactMap { approvals.ledger.entries[$0]?.presentation }))
    }

    /// The header's menu and its VoiceOver actions.
    private func headerActions(_ header: SidebarProjectHeader, order: [UUID], others: [UUID: WindowID]) -> SidebarProjectActions {
        let id = header.id
        let other = otherWindow(showing: id, in: others)
        return SidebarProjectActions(
            newWorktree: { [window] in
                SupervisionWindowActions.newWorktree(inProject: id, from: window, session: session, registry: windowRegistry)
            },
            // ⌘N makes one in the window's own project only.
            newWorktreeShortcut: header.isCurrent ? settings.settings.keyboard.shortcut(for: .newWorktree) : nil,
            moveUpShortcut: settings.settings.keyboard.shortcut(for: .moveProjectUp),
            moveDownShortcut: settings.settings.keyboard.shortcut(for: .moveProjectDown),
            moveUp: { arrange { $0.move(id, by: -1, among: projectIDs) } },
            moveDown: { arrange { $0.move(id, by: 1, among: projectIDs) } },
            moveToTop: { arrange { $0.moveToTop(id, among: projectIDs) } },
            canMoveUp: ProjectOrder.canMove(id, by: -1, in: order),
            canMoveDown: ProjectOrder.canMove(id, by: 1, in: order),
            toggle: { setCollapsed(!header.isCollapsed, id) },
            collapseOthers: { arrange { $0.collapseOthers(than: id, among: projectIDs) } },
            syncWorktrees: {
                NotificationCenter.default.post(name: .limpidGitSyncRequested, object: id)
            },
            showHiddenWorktrees: session.hasHiddenWorktrees(projectID: id)
                ? { session.unhideAllWorktrees(projectID: id) }
                : nil,
            removeMissingWorktrees: session.hasMissingWorktrees(projectID: id)
                ? {
                    withAnimation(LimpidMotion.reorderUnlessReduced) {
                        ContainerActions.pruneMissingWorktrees(session, registry: registry, projectID: id)
                    }
                }
                : nil,
            openSettings: { [window] in window.commands.send(.openProjectSettings(id)) },
            revealInFinder: {
                if let project = session.project(id) {
                    NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
                }
            },
            closeProject: { [window] in window.commands.send(.closeProject(id)) },
            bringOtherWindowForward: other.map { other in { windowRegistry.raise(other.id, in: session) } }
        )
    }

    @ViewBuilder
    private func sessionRow(_ row: SessionSidebarModel.Row, in project: Project?, others: [UUID: WindowID], now: Date) -> some View {
        let tabs = session.tabs(in: row.id)
        let info = prStatusStore.info(for: row.id)
        SessionRowView(
            row: row,
            projectName: project?.name,
            pullRequestMark: PRMarkPresentation.supervisionStyle(for: info),
            // Every row with a request opens its card from the mark,
            // whatever its state.
            pullRequestCard: row.fact.pullRequest == nil ? nil : info.map { (row.id, $0) },
            drag: row.id.worktreeID.map { SessionRowView.Drag(id: $0.uuidString, dragState: dragState) },
            isKeyboardSelected: isFocused && keyboardLine == .row(row.id),
            now: now,
            actions: actions(for: row, in: project, hasTabs: !tabs.isEmpty, others: others),
            onAnswer: answerAction(row, others: others),
            // Another project's row switches the window to it in place, or
            // brings forward the window that shows it.
            onActivate: { session.setActiveContainer(row.id, in: window.id, intent: .person) },
            // Renamed where the project is shown, as the menu's Rename is:
            // a double-click here would bring that window forward on its
            // first click and edit the name behind it on its second.
            // The scratch row is named by its own word and takes no name.
            onRename: project == nil || isInOtherWindow(project, others: others)
                ? nil
                : { session.renameRow(row.id, to: $0, runtimes: attention.allRuntimes) },
            isRenaming: Binding(
                get: { renamingRow == row.id },
                set: { renamingRow = $0 ? row.id : nil }
            )
        )
        .modifier(ApprovalRowAnchor(requests: row.answerKey.flatMap { approvals.ledger.entries[$0]?.presentation }.map { [$0] } ?? []))
        // A tab dropped on another project's row would switch the window's
        // project by a drag; only the window's own rows take one.
        .modifier(SessionRowDropTarget(
            container: row.id,
            project: project,
            acceptsTabs: project?.id == window.selection.shownProjectID,
            session: session
        ))
    }

    /// The window that shows `projectID`, if one other than this does, by
    /// the map the body read once (`WorkspaceSession.otherWindowsByProject(than:)`).
    private func otherWindow(showing projectID: UUID, in others: [UUID: WindowID]) -> ProjectWindowState? {
        others[projectID].flatMap { windowRegistry.window($0) }
    }

    /// Whether another window shows `project`, which its rows are worked
    /// on in.
    private func isInOtherWindow(_ project: Project?, others: [UUID: WindowID]) -> Bool {
        project.flatMap { otherWindow(showing: $0.id, in: others) } != nil
    }

    /// A request to bring a line into view, told apart from the one before
    /// it even when it names the same line.
    struct ScrollRequest: Equatable {
        let id = UUID()
        let line: SidebarItemID
    }

    /// The session's projects, in the session's order: what the window's
    /// order lays out.
    private var projectIDs: [UUID] {
        session.projects.map(\.id)
    }

    /// Every project's header and rows, scrolling between the heading and
    /// the foot bar.
    private func projectList(_ model: SidebarListModel, others: [UUID: WindowID]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The time steps once a minute, so a finer tick would
                // only redraw the same text. A usage limit's chip drops
                // its reset time as the limit resets, when the sync reads
                // the limits again.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let now = max(context.date, resetSync?.resetPassedAt ?? context.date)
                    // One flat list of every line, headers included,
                    // so a project of sixty rows is not one lazy unit
                    // laid out whole.
                    LazyVStack(spacing: LimpidLayout.Supervision.sessionRowSpacing) {
                        ForEach(model.items) { item in
                            line(item, in: model, others: others, now: now)
                                .id(item.id)
                        }
                    }
                    // The lines are what the list reports its place by.
                    .scrollTargetLayout()
                    .padding(.horizontal, LimpidLayout.Supervision.sidebarListInset)
                    .padding(.bottom, LimpidLayout.Supervision.sidebarListInset)
                }
            }
            // The line the arrow keys reach stays in sight; the scratch
            // row is always in sight, in the foot bar.
            .onChange(of: keyboardLine) { _, line in
                if let line, line != .row(.loose) {
                    proxy.scrollTo(line)
                }
            }
            // The lines in sight, kept beside the window: whether the
            // selected row has to be brought into view. Reported to the
            // window rather than held in the view: a state the body read
            // would rebuild every line each time one passed the edge.
            .onScrollTargetVisibilityChange(idType: SidebarItemID.self) { visible in
                window.sidebarVisibleLines = Set(visible)
            }
            // The sidebar lists every project, so a switch leaves it
            // where it is; a selected row out of sight is brought into
            // view, without motion, its header opened first.
            // At launch too, for a selected row far down the list.
            .onChange(of: window.selection.activeContainerID, initial: true) { _, row in
                reveal(row, proxy: proxy)
            }
            // A moved header stays in sight (⌥⌘↑ ⌥⌘↓).
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                withAnimation(LimpidMotion.reorderUnlessReduced) {
                    proxy.scrollTo(request.line)
                }
            }
        }
    }

    /// Where every project's rows are shown: where each belongs now, unless
    /// the pointer, the keyboard, or a drag holds them where they are.
    private func presentedSections(others: [UUID: WindowID]) -> SidebarPresentedSections {
        window.presentedSections(
            session: session,
            others: others,
            queue: attentionQueue.queue,
            pullRequest: { prStatusStore.info(for: $0) },
            gitFacts: { gitFacts.facts(for: $0) },
            isDragging: dragState.currentSourceID != nil
        )
    }

    /// Changes the window's arrangement, without motion under Reduce
    /// Motion.
    private func arrange(_ change: (inout SidebarArrangement) -> Void) {
        var next = window.selection.sidebarArrangement
        change(&next)
        guard next != window.selection.sidebarArrangement else { return }
        withAnimation(LimpidMotion.reorderUnlessReduced) {
            window.selection.sidebarArrangement = next
        }
    }

    /// Opens or folds one header. The keys on a line it folds away go to
    /// the header, so they are never on a line out of the list.
    private func setCollapsed(_ isCollapsed: Bool, _ projectID: UUID) {
        arrange { $0.setCollapsed(isCollapsed, projectID) }
        if isCollapsed, let line = keyboardLine, line.projectID == projectID, line != .header(projectID) {
            keyboardLine = .header(projectID)
        }
    }

    /// Opens or folds every header (⌥-click, ⌥← ⌥→).
    private func setAllCollapsed(_ isCollapsed: Bool) {
        arrange { $0.setAllCollapsed(isCollapsed, among: projectIDs) }
        if isCollapsed, let project = keyboardLine?.projectID, keyboardLine != .header(project) {
            keyboardLine = .header(project)
        }
    }

    /// Opens or folds one of a project's folded sections.
    private func setFold(_ section: SidebarSection, of projectID: UUID, isOpen: Bool) {
        arrange { $0.setOpen(isOpen, section, of: projectID) }
    }

    /// Meets every project the window's arrangement does not know yet, at
    /// the bottom, opened or folded by the default rule
    /// (`SidebarFoldDefault`), and lets go of those that are gone.
    /// Another window's project is told from the session's windows
    /// (`others`), which a launch has all restored before any sidebar is
    /// drawn, so one is never met open for a window not listed yet. A
    /// window whose sidebar is not on screen meets its projects when the
    /// sidebar appears; until then they are listed by the same rule.
    private func settleArrangement(sections: SidebarPresentedSections, others: [UUID: WindowID]) {
        let shown = window.selection.shownProjectID
        let settled = window.selection.sidebarArrangement.settled(projects: projectIDs) { id in
            guard let project = session.project(id) else { return false }
            return SidebarFoldDefault.isOpen(
                isCurrent: id == shown,
                isInOtherWindow: others[id] != nil,
                workingCount: sections.ordered(project).count { $0.section == .working }
            )
        }
        if settled != window.selection.sidebarArrangement {
            window.selection.sidebarArrangement = settled
        }
    }

    /// The window selected `row`: a row out of sight is brought into view,
    /// centered, without motion. The person's choice has opened its
    /// header already (`WorkspaceSession.window(for:askedOf:intent:)`); a
    /// repair opens none. The scratch row is always in sight.
    private func reveal(_ row: ContainerID, proxy: ScrollViewProxy) {
        guard row != .loose, !window.selection.isChoosingProject else { return }
        // Once the list has laid the opened header's rows out.
        Task { @MainActor in
            guard window.selection.activeContainerID == row, !window.sidebarVisibleLines.contains(.row(row)) else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(SidebarItemID.row(row), anchor: .center)
            }
        }
    }

    /// The fold line's button: Delete Worktrees on the worktrees ready to
    /// clean up, after its confirmation, and Remove All from Sidebar on the
    /// missing ones. Only the rows under the line go, read when it is
    /// pressed: one with a tab, or that the window is on, is a working row.
    /// The other worktrees have none: they are Git's, not done with.
    private func foldClear(_ fold: SessionSidebarModel.Fold) -> SidebarFoldClear? {
        guard let project = session.project(fold.projectID) else { return nil }
        switch fold.section {
        case .cleanable:
            return SidebarFoldClear(kind: .deleteAll) {
                let worktrees = worktrees(under: fold, of: project)
                // One is confirmed as its row's Delete Worktree is, by name
                // and folder, with the Force retry when Git asks for it.
                if worktrees.count == 1, let worktree = worktrees.first {
                    deletingWorktree = DeleteWorktreeTarget(
                        projectID: project.id,
                        worktreeID: worktree.id,
                        label: worktree.label,
                        path: worktree.workingDirectory
                    )
                } else if !worktrees.isEmpty {
                    deletingWorktrees = DeleteWorktreesTarget(
                        projectID: project.id,
                        worktrees: worktrees.map { .init(worktreeID: $0.id, label: $0.label) }
                    )
                }
            }
        case .missing:
            return SidebarFoldClear(kind: .removeAll) {
                for worktree in worktrees(under: fold, of: project) {
                    WorktreeHiding.removeMissing(session: session, registry: registry, projectID: project.id, worktreeID: worktree.id)
                }
            }
        case .working, .other:
            return nil
        }
    }

    /// The worktrees of `project` listed under `fold`.
    private func worktrees(under fold: SessionSidebarModel.Fold, of project: Project) -> [Worktree] {
        let sections = window.presentedSections
        return project.worktrees.filter { worktree in
            !worktree.isHidden && sections.section(of: .worktree(projectID: project.id, worktreeID: worktree.id)) == fold.section
        }
    }

    /// The scratch row has no worktree to hide or delete: it closes its
    /// tabs and shows the folder a new one starts in, as Settings' scratch
    /// folder resolves it (the previous tab's folder by default), and home
    /// when that names none. Home alone would name another folder than the
    /// scratch tabs' as soon as one had moved.
    private var scratchActions: SessionRowActions {
        SessionRowActions(
            revealInFinder: {
                let folder = session.scratchStartDirectory(in: window.id) ?? FileManager.default.homeDirectoryForCurrentUser
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            },
            closeAllTabs: session.tabs(in: .loose).isEmpty ? nil : {
                TabActions.closeAllTabs(session, registry: registry, in: .loose, agentProjection: agentProjection, from: window.id)
            }
        )
    }

    /// Where ⌥⌘0 puts the keys: the open row, or its project's header while
    /// that is folded; the scratch row when the window is on it.
    private func initialKeyboardLine(in model: SidebarListModel) -> SidebarItemID {
        let row = SidebarItemID.row(window.selection.activeContainerID)
        guard row != .row(.loose), !model.items.contains(where: { $0.id == row }),
              let projectID = window.selection.activeContainerID.projectID
        else { return row }
        return .header(projectID)
    }

    /// ↑ ↓ ← → and Return while the sidebar has the keyboard
    /// (`SidebarKeyboardCursor`). ⌘ and ⌃ leave the key to the menus.
    private func handleKey(_ press: KeyPress, in model: SidebarListModel) -> KeyPress.Result {
        guard ownsKeys, press.modifiers.isDisjoint(with: [.command, .control]), let key = Self.cursorKey(press) else {
            return .ignored
        }
        // A held Return acts once; the arrows walk on as they repeat.
        if key == .return, press.phase != .down {
            return .handled
        }
        let arrangement = window.selection.sidebarArrangement
        let headers = Dictionary(model.headers.map { ($0.id, $0.isCollapsed) }) { first, _ in first }
        let action = SidebarKeyboardCursor.action(
            for: key,
            isOption: press.modifiers.contains(.option),
            at: keyboardLine,
            in: SidebarKeyboardCursor.Lines(
                ids: model.items.map(\.id) + [.row(.loose)],
                isCollapsed: { headers[$0] ?? true },
                isFoldOpen: { arrangement.isOpen($1, of: $0) }
            )
        )
        switch action {
        case let .move(line):
            keyboardLine = line
        case let .setCollapsed(projectID, isCollapsed):
            setCollapsed(isCollapsed, projectID)
        case let .setAllCollapsed(isCollapsed):
            setAllCollapsed(isCollapsed)
        case let .setFoldOpen(projectID, section, isOpen):
            setFold(section, of: projectID, isOpen: isOpen)
        case let .activate(row):
            session.setActiveContainer(row, in: window.id, intent: .person)
            returnKeyboardToTerminal()
        case .none:
            break
        }
        return .handled
    }

    /// The cursor's key for `press`; `nil` for one it leaves alone, and
    /// for Return with a modifier.
    private static func cursorKey(_ press: KeyPress) -> SidebarKeyboardCursor.Key? {
        switch press.key {
        case .upArrow: .up
        case .downArrow: .down
        case .leftArrow: .left
        case .rightArrow: .right
        case .return: press.modifiers.isEmpty ? .return : nil
        default: nil
        }
    }

    /// The window's key, seen ahead of the menus while the sidebar has the
    /// keyboard: Move Project Up and Down (⌥⌘↑ ⌥⌘↓ by default) move the
    /// project of the line the keys are on, else the window's
    /// (`SidebarKeyRoute`). `true` takes the key.
    private func handleMonitoredKey(_ event: NSEvent, in nsWindow: NSWindow) -> Bool {
        let route = SidebarKeyRoute.route(
            for: event,
            keyboard: settings.settings.keyboard,
            hasKeyboard: ownsKeys,
            isComposing: nsWindow.isComposingText
        )
        guard case let .moveProject(offset) = route else { return false }
        if let projectID = SidebarKeyboardCursor.projectToMove(at: keyboardLine, shown: window.selection.shownProjectID) {
            arrange { $0.move(projectID, by: offset, among: projectIDs) }
            scrollRequest = ScrollRequest(line: .header(projectID))
        }
        return true
    }

    /// Esc, or a row opened from the keyboard: the terminal takes the keys
    /// back.
    private func returnKeyboardToTerminal() {
        isFocused = false
        guard let paneID = session.activeTab(in: window.id)?.splitTree.effectiveFocusedLeafID else { return }
        KeyboardHandoff.returnToTerminal(paneID: paneID, registry: registry, keeper: .terminalOrTextField, timing: .nextTurn)
    }

    /// Answer…: in this window's card, or, on a row of a project another
    /// window shows, in that window's, which comes forward.
    private func answerAction(_ row: SessionSidebarModel.Row, others: [UUID: WindowID]) -> (() -> Void)? {
        guard let key = row.answerKey, let request = approvals.ledger.entries[key]?.presentation else { return nil }
        let other = row.id.projectID.flatMap { otherWindow(showing: $0, in: others) }
        // Hidden while the card is already up for it.
        guard !(other ?? window).approvalCard.isPresenting(key, in: approvals) else { return nil }
        return { [window] in
            SupervisionWindowActions.answer(
                request,
                inProject: row.id.projectID,
                from: window,
                approvals: approvals,
                session: session,
                registry: windowRegistry
            )
        }
    }

    private func actions(
        for row: SessionSidebarModel.Row,
        in project: Project?,
        hasTabs: Bool,
        others: [UUID: WindowID]
    ) -> SessionRowActions {
        guard let project else { return SessionRowActions() }
        // The project's own folder is never hidden, deleted, or moved.
        let worktree = row.isMainFolder
            ? nil
            : row.id.worktreeID.flatMap { session.worktree(projectID: project.id, worktreeID: $0) }
        let folder = worktree?.workingDirectory ?? project.rootURL
        // A project another window shows is worked on in that window:
        // what the menu opens or moves goes there.
        let other = otherWindow(showing: project.id, in: others)
        return SessionRowActions(
            moveUp: worktree.map { worktree in
                let move: () -> Void = {
                    withAnimation(LimpidMotion.reorderUnlessReduced) {
                        session.moveWorktreeUp(projectID: project.id, worktreeID: worktree.id)
                    }
                }
                return move
            },
            moveDown: worktree.map { worktree in
                let move: () -> Void = {
                    withAnimation(LimpidMotion.reorderUnlessReduced) {
                        session.moveWorktreeDown(projectID: project.id, worktreeID: worktree.id)
                    }
                }
                return move
            },
            canMoveUp: worktree.map { session.canMoveWorktreeUp(projectID: project.id, worktreeID: $0.id) } ?? false,
            canMoveDown: worktree.map { session.canMoveWorktreeDown(projectID: project.id, worktreeID: $0.id) } ?? false,
            // Renamed where the project is shown, as the double-click is.
            // A row with no tab is renamed too: the name is the row's own
            // (`WorkspaceSession.renameRow`). Submitting the name the row
            // showed when the edit began never gets there
            // (`InlineRenameField.submission`), so a branch's name is never
            // frozen into the row; an empty name hands the row back to the
            // name it would have.
            rename: other == nil ? { renamingRow = row.id } : nil,
            removeLabel: other == nil && row.label != nil
                ? { session.renameRow(row.id, to: "", runtimes: attention.allRuntimes) }
                : nil,
            openPullRequest: prStatusStore.info(for: row.id).map { info in
                SessionRowActions.Entry(
                    title: "Open on \(info.forge.displayName)",
                    systemImage: "arrow.up.right.square"
                ) {
                    NSWorkspace.shared.open(info.url)
                }
            },
            refreshPRStatus: prStatusStore.info(for: row.id).flatMap { _ in
                prStatusSyncer.map { syncer in { syncer.refreshNow(container: row.id) } }
            },
            revealInFinder: row.isMissing ? nil : { NSWorkspace.shared.activateFileViewerSelecting([folder]) },
            openChangesPanel: row.isMissing ? nil : { [window] in
                SupervisionWindowActions.openChangesPanel(row.id, from: window, session: session, registry: windowRegistry)
            },
            removeFromWorking: worktree.flatMap { worktree in
                guard SessionSidebarModel.offersRemoveFromWorking(row, worktree: worktree, hasTabs: hasTabs),
                      other?.selection.activeContainerID != row.id
                else { return nil }
                return {
                    WorktreeHiding.removeFromWorking(
                        session: session,
                        windows: windowRegistry.windows,
                        toastCenter: toastCenter,
                        projectID: project.id,
                        worktree: worktree
                    )
                }
            },
            hide: worktree.flatMap { worktree in
                worktree.isMissing ? nil : {
                    WorktreeHiding.hide(session: session, toastCenter: toastCenter, projectID: project.id, worktree: worktree)
                }
            },
            removeMissing: worktree.flatMap { worktree in
                worktree.isMissing ? {
                    WorktreeHiding.removeMissing(session: session, registry: registry, projectID: project.id, worktreeID: worktree.id)
                } : nil
            },
            deleteWorktree: worktree.flatMap { worktree in
                worktree.isMissing ? nil : {
                    deletingWorktree = DeleteWorktreeTarget(
                        projectID: project.id,
                        worktreeID: worktree.id,
                        label: worktree.label,
                        path: worktree.workingDirectory
                    )
                }
            },
            closeAllTabs: hasTabs ? {
                TabActions.closeAllTabs(session, registry: registry, in: row.id, agentProjection: agentProjection, from: window.id)
            } : nil
        )
    }
}

/// Drop a worktree's row on another of its project's to reorder them, and a
/// tab on a row of the window's project to move it there. The project's own
/// folder takes tabs, and nothing is dropped beside it.
private struct SessionRowDropTarget: ViewModifier {
    let container: ContainerID
    /// `nil` for the scratch row, which belongs to no project.
    let project: Project?
    /// Whether a tab may be dropped on the row: only on the window's own
    /// project's rows and the scratch row, so a drag never switches the
    /// window's project.
    let acceptsTabs: Bool
    let session: WorkspaceSession

    func body(content: Content) -> some View {
        if let project, let worktreeID = container.worktreeID {
            content.reorderableDropTarget(
                targetID: "session-\(worktreeID)",
                acceptedPrefixes: acceptsTabs ? ["tab:", "worktree:"] : ["worktree:"],
                tabAsContainerAssignment: true,
                isNoOp: { sourceID, position in
                    session.isNoOpDrop(of: sourceID, onWorktree: worktreeID, projectID: project.id, position: position)
                },
                onDrop: { prefix, sourceID, position in
                    if prefix == "tab:" {
                        session.moveTab(sourceID, to: container)
                        // The person put work there: one of the other
                        // worktrees becomes theirs, and stays a working row
                        // once the tab closes. Only once the tab is there.
                        if session.tab(sourceID)?.container == container {
                            session.admitWorktree(container, intent: .person)
                        }
                    } else if session.projectID(forWorktree: sourceID) == project.id {
                        session.reorderWorktree(projectID: project.id, sourceID: sourceID, target: worktreeID, position: position)
                    }
                }
            )
        } else {
            content.reorderableDropTarget(
                targetID: "session-\(container)",
                acceptedPrefixes: acceptsTabs ? ["tab:"] : [],
                tabAsContainerAssignment: true,
                isNoOp: { sourceID, _ in session.tab(sourceID)?.container == container },
                onDrop: { _, sourceID, _ in session.moveTab(sourceID, to: container) }
            )
        }
    }
}

/// Answer… opens the card beside the row it came from, or beside a folded
/// project's header for the requests inside it. The line keeps its frame
/// when a request arrives, so the frame is reported again for each new
/// request, not only when it moves.
private struct ApprovalRowAnchor: ViewModifier {
    let requests: [ApprovalPresentation]
    @Environment(ApprovalPresentationStore.self) private var approvals
    /// Each window's card points at its own rows.
    @Environment(ProjectWindowState.self) private var window
    /// Not read by `body`, so a resize does not redraw the line.
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            // Measured only while the line has a request: every line
            // measured its global frame on every frame of a scroll or a
            // slide for the one or two that hold one. In the background, so
            // the line keeps its identity as a request comes and goes; it
            // measures the line's frame, which it fills.
            .background {
                if !requests.isEmpty {
                    Color.clear
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newFrame in
                            frame = newFrame
                            report()
                        }
                }
            }
            .onChange(of: requests.map(\.id)) { report() }
    }

    private func report() {
        // A sidebar on its way out still moves, off screen; what it reports
        // would undo the anchors forgotten when it went, or when its window
        // closed (`WindowClosing.tidy`).
        guard let frame, window.isSidebarPresented, !window.isClosed else { return }
        for request in requests {
            window.approvalCard.updateRowAnchor(frame, for: request, in: approvals)
        }
    }
}

@MainActor
extension SidebarKeyRoute {
    /// The route for a key-down AppKit sees at the window, read as the
    /// Keyboard pane records keys (`StoredShortcut.capture(from:)`), so the
    /// keys a person bound there are the keys that match here.
    static func route(for event: NSEvent, keyboard: KeyboardSettings, hasKeyboard: Bool, isComposing: Bool) -> Route {
        route(pressed: StoredShortcut.capture(from: event), keyboard: keyboard, hasKeyboard: hasKeyboard, isComposing: isComposing)
    }
}
