// ProjectSectionView.swift
// Limpid — one project's slice of the container slab: the header row, its
// drag/drop target, and (when expanded) every worktree row
// underneath. Lives in its own view so `ContainerSlabView`
// can stay short — that file now owns section composition + sheet /
// alert state, while per-project rendering / wiring lands here.
//
// Sheet / alert presentation is driven through `@Binding`s the slab
// owns. We deliberately push the state up rather than scope it per
// project because alerts/sheets are window-scoped — having two open
// simultaneously is meaningless.

import AppKit
import SwiftUI

struct ProjectSectionView: View {
    @Environment(WindowSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(LimpidDragState.self) private var dragState
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.surfaceRegistry) private var registry

    let project: Project
    @Binding var creatingWorktreeFor: UUID?
    @Binding var openSettingsFor: ContainerSettingsTarget?
    @Binding var deletingWorktree: ContainerSlabView.DeleteWorktreeTarget?
    @Binding var removingProject: ContainerSlabView.RemoveProjectTarget?
    @Binding var worktreeOperationError: String?

    /// `true` when there's nothing to nest under the project header —
    /// either the project isn't a git repository or `GitSyncCoordinator`
    /// hasn't run its first pass yet. The header navigates to
    /// `.project(id)` regardless; in flat mode we additionally hide
    /// the disclosure chevron and skip rendering the (empty)
    /// worktree list.
    private var isFlat: Bool {
        project.worktrees.allSatisfy(\.isHidden)
    }

    var body: some View {
        // `spacing: 0` because the gap under the header belongs to the
        // worktree stack's animated height, not to this stack. A
        // collapsed stack is still a child at zero height, so a gap
        // owned by this stack would survive the collapse and leave the
        // folded project sitting on a gap that belongs to nobody.
        VStack(alignment: .leading, spacing: 0) {
            projectHeader
            if !isFlat {
                worktreeStack
            }
        }
    }

    /// The project's worktree rows, revealed by animating this stack's
    /// height rather than by inserting it.
    ///
    /// Inserting them does not work. Under a `.transition` the rows
    /// appeared at their final position while the projects below were
    /// still sliding down, so the two drew on top of each other for
    /// the length of the animation. Changing the transition, the
    /// container type, and where the animation was attached all made
    /// no difference — nothing was transitioning at all.
    ///
    /// Why the transition was skipped was never established. The
    /// obvious explanation, that the fold reaches the view through
    /// Observation outside an animated transaction, does not hold:
    /// `onToggleExpand` below flips the flag inside `withAnimation`.
    /// Recording the symptom rather than a mechanism we could not
    /// confirm, because the fix does not depend on which it was.
    ///
    /// A height is a plain interpolatable value, so the rows below
    /// move as a direct consequence of it in the same layout pass, and
    /// `clipped()` makes overlap impossible rather than unlikely. The
    /// cost is that the rows stay mounted while collapsed, hence
    /// hit testing off — a clipped row must not answer a click.
    ///
    /// A "Default" row for the project itself used to live here but
    /// was redundant: tapping the project header already activates
    /// `.project(id)`.
    private var worktreeStack: some View {
        VStack(alignment: .leading, spacing: LimpidLayout.reorderRowSpacing) {
            ForEach(project.worktrees.filter { !$0.isHidden }) { wt in
                worktreeRow(wt)
            }
        }
        // The rule spans the rows only, not the gap above them. It used
        // to run up into that gap so it would meet the dot it descends
        // from, but the header carries a pill whenever one of these
        // worktrees owns selection, and a rule running into that pill's
        // edge reads as a collision rather than as descent. Alignment
        // already carries the relationship: the rule is centered on the
        // marker slot, so it falls directly under the project's dot.
        .overlay(alignment: .leading) { worktreeRule }
        .padding(.top, LimpidLayout.reorderRowSpacing)
        .frame(height: project.isExpanded ? Self.worktreeStackHeight(for: project) : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(project.isExpanded)
        .accessibilityHidden(!project.isExpanded)
    }

    /// Height the worktree stack occupies when open, including the gap
    /// that separates it from its header.
    ///
    /// Computed, not measured: measuring the natural height of a view
    /// whose height we are also imposing is circular — the collapsed
    /// frame would report zero and the stack could never open again.
    /// Rows are a fixed height, so the arithmetic is exact. Static so
    /// the enclosing section can total its own height the same way.
    static func worktreeStackHeight(for project: Project) -> CGFloat {
        let count = project.worktrees.count { !$0.isHidden }
        guard count > 0 else { return 0 }
        return LimpidLayout.reorderRowSpacing
            + CGFloat(count) * LimpidLayout.containerColumnRowHeight
            + CGFloat(count - 1) * LimpidLayout.reorderRowSpacing
    }

    /// Height of everything this view draws for `project` — the header
    /// plus, when it is open, its worktrees.
    static func blockHeight(for project: Project) -> CGFloat {
        let header = LimpidLayout.containerColumnRowHeight
        guard project.isExpanded else { return header }
        return header + worktreeStackHeight(for: project)
    }

    /// Vertical rule spanning this project's worktree rows, in the
    /// project's own palette color.
    ///
    /// It answers "how far does this project reach", which nothing
    /// else does: every row shares one left edge, so the list alone
    /// cannot say where one project ends and the next begins. The
    /// palette color rather than a neutral hairline is what ties the
    /// span to the dot it descends from, damped because the two are
    /// not peers — the dot is the identity and the disclosure control,
    /// the rule only marks extent.
    private var worktreeRule: some View {
        Capsule()
            .fill(LimpidColor.paletteColor(project.paletteIndex).opacity(0.45))
            .frame(width: LimpidLayout.containerColumnProjectRuleWidth)
            .offset(
                x: LimpidLayout.containerColumnProjectRuleCenter
                    - LimpidLayout.containerColumnProjectRuleWidth / 2
            )
            .accessibilityHidden(true)
    }

    // MARK: - Project header

    /// `true` when the header should aggregate state across the
    /// project-direct container *and* every worktree. Only while the
    /// worktree list is hidden — once expanded, each worktree row
    /// carries its own bell / agent badge, so a project-wide aggregate
    /// on the header would double-count and visually compete with the
    /// children. When expanded we narrow scope to the project-direct
    /// container the header itself activates.
    private var aggregatesWholeProject: Bool {
        isFlat || !project.isExpanded
    }

    private var projectHeader: some View {
        ContainerRow(
            kind: .projectHeader(project, isExpanded: project.isExpanded),
            // Strict match: the header's strong "selected" pill only
            // fires when the project-direct container is active. When a
            // worktree under this project is active we fall through to
            // `isDescendantActive` for a softer ancestor-active pill,
            // so the actual selection (the worktree row) stays the
            // dominant visual.
            isActive: session.activeContainerID == .project(project.id),
            isDescendantActive: {
                if case let .worktree(pid, _) = session.activeContainerID {
                    return pid == project.id
                }
                return false
            }(),
            hasUnread: aggregatesWholeProject
                ? session.hasUnreadInProject(project.id)
                : session.hasUnread(in: .project(project.id)),
            isRinging: aggregatesWholeProject
                ? session.isRingingInProject(project.id)
                : session.isRinging(in: .project(project.id)),
            agentState: aggregatesWholeProject
                ? attention.aggregateAgentStateInProject(project.id, session: session)
                : attention.aggregateAgentState(in: .project(project.id), session: session),
            agentStateViewed: aggregatesWholeProject
                ? attention.isFinishedAggregateViewedInProject(project.id, session: session)
                : attention.isFinishedAggregateViewed(in: .project(project.id), session: session),
            agentBreakdown: aggregatesWholeProject
                ? attention.agentStateBreakdownInProject(project.id, session: session)
                : attention.agentStateBreakdown(in: .project(project.id), session: session),
            // Header tap always activates `.project(id)` — the
            // project-direct ("Default") container. With worktrees,
            // expansion is a separate hit target on the leading
            // palette dot, so the rename double-tap conflict that used
            // to require an inert header is no longer in play.
            // Worktree-yes / worktree-no rows now behave the same on
            // body tap.
            onActivate: { session.setActiveContainer(.project(project.id)) },
            onToggleExpand: isFlat ? nil : {
                withAnimation(LimpidMotion.expand) {
                    session.toggleProjectExpanded(project.id)
                }
            },
            onRename: { session.renameProject(project.id, to: $0) },
            actions: ContainerRowActions(
                onDelete: {
                    removingProject = ContainerSlabView.RemoveProjectTarget(
                        projectID: project.id,
                        name: project.name
                    )
                },
                onChangePalette: { idx in
                    session.setProjectPaletteIndex(project.id, to: idx)
                },
                onMoveUp: {
                    withAnimation(LimpidMotion.reorder) {
                        session.moveProjectUp(project.id)
                    }
                },
                onMoveDown: {
                    withAnimation(LimpidMotion.reorder) {
                        session.moveProjectDown(project.id)
                    }
                },
                canMoveUp: session.canMoveProjectUp(project.id),
                canMoveDown: session.canMoveProjectDown(project.id),
                // Hide "New Worktree…" when the project has no git
                // worktree list to grow — `git worktree add` would
                // fail on a non-repo anyway. The menu item reappears
                // after the user runs `git init` and `GitSyncCoordinator`
                // picks up the new repo on its next pass.
                onCreateWorktree: project.mainBranchName == nil
                    ? nil
                    : { creatingWorktreeFor = project.id },
                onShowHiddenWorktrees: session.hasHiddenWorktrees(projectID: project.id)
                    ? { session.unhideAllWorktrees(projectID: project.id) }
                    : nil,
                onOpenSettings: { openSettingsFor = .project(project.id) },
                onSyncWorktrees: {
                    NotificationCenter.default.post(
                        name: .limpidGitSyncRequested,
                        object: project.id
                    )
                },
                onPruneMissingWorktrees: session.hasMissingWorktrees(projectID: project.id)
                    ? {
                        withAnimation(LimpidMotion.reorder) {
                            ContainerActions.pruneMissingWorktrees(
                                session,
                                registry: registry,
                                projectID: project.id
                            )
                        }
                    }
                    : nil
            ),
            // Drag attaches from inside the row body so the row's
            // tap / context-menu gestures don't claim the hit area
            // first on macOS 26.
            dragDescriptor: ContainerRow.DragDescriptor(
                kind: .project,
                prefix: "project:",
                id: project.id.uuidString,
                dragState: dragState
            )
        )
        .reorderableDropTarget(
            targetID: "project-\(project.id)",
            acceptedPrefixes: ["tab:", "project:"],
            tabAsContainerAssignment: true,
            isNoOp: { sourceID, position in
                // A project's own worktrees are *separate* containers:
                // a tab living in one of them still moves when dropped
                // on the project body, so match the body itself, not
                // the shared `projectID`. Matching `projectID` here
                // would suppress the `+` badge for worktree tabs.
                if let src = session.tab(sourceID),
                   src.container == .project(project.id)
                {
                    return true
                }
                if sourceID == project.id {
                    return true
                }
                guard let srcIdx = session.projects.firstIndex(where: { $0.id == sourceID }),
                      let tgtIdx = session.projects.firstIndex(where: { $0.id == project.id })
                else { return false }
                switch position {
                case .before: return srcIdx == tgtIdx - 1
                case .after: return srcIdx == tgtIdx + 1
                }
            },
            onDrop: { prefix, sourceID, position in
                if prefix == "tab:" {
                    session.moveTab(sourceID, to: .project(project.id))
                } else if prefix == "project:" {
                    session.reorderProject(sourceID: sourceID, target: project.id, position: position)
                }
            }
        )
    }

    // MARK: - Worktree row

    private func worktreeRow(_ wt: Worktree) -> some View {
        ContainerRow(
            kind: .worktree(projectID: project.id, wt),
            isActive: session.activeContainerID == .worktree(projectID: project.id, worktreeID: wt.id),
            hasUnread: session.hasUnread(in: .worktree(projectID: project.id, worktreeID: wt.id)),
            isRinging: session.isRinging(in: .worktree(projectID: project.id, worktreeID: wt.id)),
            agentState: attention.aggregateAgentState(in: .worktree(projectID: project.id, worktreeID: wt.id), session: session),
            agentStateViewed: attention.isFinishedAggregateViewed(
                in: .worktree(projectID: project.id, worktreeID: wt.id),
                session: session
            ),
            agentBreakdown: attention.agentStateBreakdown(in: .worktree(projectID: project.id, worktreeID: wt.id), session: session),
            onActivate: {
                session.setActiveContainer(.worktree(projectID: project.id, worktreeID: wt.id))
            },
            onToggleExpand: nil,
            // Worktree rename is intentionally not exposed. Branch /
            // folder rename is git's job — users drop into a tab and
            // run `git branch -m` / `git worktree move` directly. The
            // sidebar follows on the next GitSync pass.
            onRename: nil,
            actions: ContainerRowActions(
                onDelete: {
                    // Missing rows: drop entirely (no disk left to
                    // hide). Live rows: hide so the user can recover
                    // via "Show Hidden Worktrees" — that path animates
                    // itself, so only the removal is wrapped here.
                    if wt.isMissing {
                        withAnimation(LimpidMotion.reorder) {
                            ContainerActions.removeWorktree(
                                session,
                                registry: registry,
                                projectID: project.id,
                                worktreeID: wt.id
                            )
                        }
                    } else {
                        hideWorktreeWithUndo(projectID: project.id, worktreeID: wt.id, label: wt.label)
                    }
                },
                onMoveUp: {
                    withAnimation(LimpidMotion.reorder) {
                        session.moveWorktreeUp(projectID: project.id, worktreeID: wt.id)
                    }
                },
                onMoveDown: {
                    withAnimation(LimpidMotion.reorder) {
                        session.moveWorktreeDown(projectID: project.id, worktreeID: wt.id)
                    }
                },
                canMoveUp: session.canMoveWorktreeUp(projectID: project.id, worktreeID: wt.id),
                canMoveDown: session.canMoveWorktreeDown(projectID: project.id, worktreeID: wt.id),
                onDeleteOnDisk: wt.isMissing ? nil : {
                    // Disk-side delete (= `git worktree remove`) only
                    // makes sense when the worktree still exists.
                    // Orphan rows go via the context menu's remove
                    // entry instead, which maps to `onDelete`.
                    deletingWorktree = ContainerSlabView.DeleteWorktreeTarget(
                        projectID: project.id,
                        worktreeID: wt.id,
                        label: wt.label,
                        path: wt.workingDirectory
                    )
                },
                onRevealInFinder: {
                    NSWorkspace.shared.activateFileViewerSelecting([wt.workingDirectory])
                },
                helpText: wt.workingDirectory.path
            ),
            // Drag attaches from inside the row body so the row's
            // tap / context-menu gestures don't claim the hit area
            // first on macOS 26.
            dragDescriptor: ContainerRow.DragDescriptor(
                kind: .worktree,
                prefix: "worktree:",
                id: wt.id.uuidString,
                dragState: dragState
            )
        )
        .reorderableDropTarget(
            targetID: "worktree-\(wt.id)",
            acceptedPrefixes: ["tab:", "worktree:"],
            tabAsContainerAssignment: true,
            isNoOp: { sourceID, position in
                if let src = session.tab(sourceID),
                   case let .worktree(pid, wid) = src.container,
                   pid == project.id, wid == wt.id
                {
                    return true
                }
                if let srcProjectID = session.projectID(forWorktree: sourceID) {
                    guard srcProjectID == project.id else { return true }
                    if sourceID == wt.id {
                        return true
                    }
                    guard let si = project.worktrees.firstIndex(where: { $0.id == sourceID }),
                          let ti = project.worktrees.firstIndex(where: { $0.id == wt.id })
                    else { return false }
                    switch position {
                    case .before: return si == ti - 1
                    case .after: return si == ti + 1
                    }
                }
                return false
            },
            onDrop: { prefix, sourceID, position in
                if prefix == "tab:" {
                    session.moveTab(sourceID, to: .worktree(projectID: project.id, worktreeID: wt.id))
                } else if prefix == "worktree:" {
                    if session.projectID(forWorktree: sourceID) == project.id {
                        session.reorderWorktree(
                            projectID: project.id,
                            sourceID: sourceID,
                            target: wt.id,
                            position: position
                        )
                    }
                }
            }
        )
    }

    /// Hide path with an Undo toast. The hide itself runs immediately
    /// (sidebar feels responsive); the toast carries a closure that
    /// re-shows the row if the user catches the action in time. After
    /// 5 s the toast auto-dismisses and the hide stays. Matches the
    /// Apple Mail "deleted message" pattern.
    ///
    /// Lives in the View layer rather than `TabActions` on
    /// purpose: it's UI-orchestration (animation + toast) wrapped
    /// around two existing pure session verbs (`hideWorktree` /
    /// `unhideWorktree`). Moving it to `TabActions` would force
    /// that enum to import SwiftUI + know about `ToastCenter`, which
    /// breaks the rule "TabActions takes session + registry only,
    /// no UI deps."
    private func hideWorktreeWithUndo(projectID: UUID, worktreeID: UUID, label: String) {
        withAnimation(LimpidMotion.reorder) {
            session.hideWorktree(projectID: projectID, worktreeID: worktreeID)
        }
        toastCenter.show(ToastItem(
            message: String(localized: "Hid worktree \u{201C}\(label)\u{201D}"),
            undo: { [session] in
                withAnimation(LimpidMotion.reorder) {
                    session.unhideWorktree(projectID: projectID, worktreeID: worktreeID)
                }
            }
        ))
    }
}
