// ProjectSectionView.swift
// Limpid — one project's slice of the L1 slab: the header row, its
// drag/drop target, and (when expanded) the "general" row + every
// worktree row underneath. Lives in its own view so `ContainerSlabView`
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
    @Environment(LimpidDragState.self) private var dragState
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.surfaceRegistry) private var registry

    let project: Project
    @Binding var creatingWorktreeFor: UUID?
    @Binding var openSettingsFor: UUID?
    @Binding var deletingWorktree: ContainerSlabView.DeleteWorktreeTarget?
    @Binding var removingProject: ContainerSlabView.RemoveProjectTarget?
    @Binding var worktreeOperationError: String?

    var body: some View {
        projectHeader
        if project.isExpanded {
            // Wrap the nested children in a single Group so SwiftUI
            // applies one slide-up transition to the whole subtree —
            // matches the GROUPS section's collapse animation.
            Group {
                projectGeneralRow
                ForEach(project.worktrees.filter { !$0.isHidden }) { wt in
                    worktreeRow(wt)
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Project header

    private var projectHeader: some View {
        ContainerRow(
            kind: .projectHeader(
                project,
                totalCount: session.tabs.count(where: { $0.container.projectID == project.id }),
                isExpanded: project.isExpanded
            ),
            isActive: session.activeContainerID.projectID == project.id,
            hasUnread: session.hasUnreadInProject(project.id),
            isRinging: session.isRingingInProject(project.id),
            // Body taps are inert; the chevron is the sole expand
            // control. Single-tap-to-fold conflicted with the rename
            // double-tap — rapid clicks stacked `withAnimation`
            // transactions until SwiftUI's layout deadlocked.
            onActivate: {},
            onToggleExpand: {
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
                onCreateWorktree: { creatingWorktreeFor = project.id },
                onShowHiddenWorktrees: session.hasHiddenWorktrees(projectID: project.id)
                    ? { session.unhideAllWorktrees(projectID: project.id) }
                    : nil,
                onOpenSettings: { openSettingsFor = project.id },
                onSyncWorktrees: {
                    NotificationCenter.default.post(
                        name: .limpidGitSyncRequested,
                        object: project.id
                    )
                },
                onPruneMissingWorktrees: session.hasMissingWorktrees(projectID: project.id)
                    ? {
                        withAnimation(LimpidMotion.reorder) {
                            SessionActions.pruneMissingWorktrees(
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
                if let src = session.tab(sourceID),
                   src.container.projectID == project.id
                {
                    return true
                }
                if sourceID == project.id { return true }
                guard let srcIdx = session.projects.firstIndex(where: { $0.id == sourceID }),
                      let tgtIdx = session.projects.firstIndex(where: { $0.id == project.id })
                else { return false }
                switch position {
                case .before: return srcIdx == tgtIdx - 1
                case .after: return srcIdx == tgtIdx + 1
                }
            }
        ) { prefix, sourceID, position in
            if prefix == "tab:" {
                session.moveTab(sourceID, to: .project(project.id))
            } else if prefix == "project:" {
                session.reorderProject(sourceID: sourceID, target: project.id, position: position)
            }
        }
    }

    // MARK: - "general" row

    private var projectGeneralRow: some View {
        ContainerRow(
            kind: .projectGeneral(project, count: session.directTabs(in: project.id).count),
            isActive: session.activeContainerID == .project(project.id),
            hasUnread: session.hasUnread(in: .project(project.id)),
            isRinging: session.isRinging(in: .project(project.id)),
            onActivate: { session.setActiveContainer(.project(project.id)) },
            onToggleExpand: nil,
            onRename: nil
        )
        .reorderableDropTarget(
            targetID: "general-\(project.id)",
            acceptedPrefixes: ["tab:"],
            tabAsContainerAssignment: true,
            isNoOp: { sourceID, _ in
                guard let src = session.tab(sourceID) else { return false }
                if case let .project(pid) = src.container, pid == project.id { return true }
                return false
            }
        ) { _, sourceID, _ in
            session.moveTab(sourceID, to: .project(project.id))
        }
    }

    // MARK: - Worktree row

    private func worktreeRow(_ wt: Worktree) -> some View {
        ContainerRow(
            kind: .worktree(
                projectID: project.id,
                wt,
                count: session.tabs(inProject: project.id, worktree: wt.id).count
            ),
            isActive: session.activeContainerID == .worktree(projectID: project.id, worktreeID: wt.id),
            hasUnread: session.hasUnread(in: .worktree(projectID: project.id, worktreeID: wt.id)),
            isRinging: session.isRinging(in: .worktree(projectID: project.id, worktreeID: wt.id)),
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
                    withAnimation(LimpidMotion.reorder) {
                        // Missing rows: drop entirely (no disk left to
                        // hide). Live rows: hide so the user can
                        // recover via "Show Hidden Worktrees".
                        if wt.isMissing {
                            SessionActions.removeWorktree(
                                session,
                                registry: registry,
                                projectID: project.id,
                                worktreeID: wt.id
                            )
                        } else {
                            hideWorktreeWithUndo(projectID: project.id, worktreeID: wt.id, label: wt.label)
                        }
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
                    // Orphan rows go via the hover "x" → onDelete.
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
                    if sourceID == wt.id { return true }
                    guard let si = project.worktrees.firstIndex(where: { $0.id == sourceID }),
                          let ti = project.worktrees.firstIndex(where: { $0.id == wt.id })
                    else { return false }
                    switch position {
                    case .before: return si == ti - 1
                    case .after: return si == ti + 1
                    }
                }
                return false
            }
        ) { prefix, sourceID, position in
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
    }

    /// Hide path with an Undo toast. The hide itself runs immediately
    /// (sidebar feels responsive); the toast carries a closure that
    /// re-shows the row if the user catches the action in time. After
    /// 5 s the toast auto-dismisses and the hide stays. Matches the
    /// Apple Mail "deleted message" pattern.
    ///
    /// Lives in the View layer rather than `SessionActions` on
    /// purpose: it's UI-orchestration (animation + toast) wrapped
    /// around two existing pure session verbs (`hideWorktree` /
    /// `unhideWorktree`). Moving it to `SessionActions` would force
    /// that enum to import SwiftUI + know about `ToastCenter`, which
    /// breaks the rule "SessionActions takes session + registry only,
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
