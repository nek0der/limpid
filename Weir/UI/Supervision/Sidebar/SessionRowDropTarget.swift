// SessionRowDropTarget.swift
// Weir — the sidebar's lines as drop targets: their names, what each takes, and the project's mark behind them.

import SwiftUI

/// The piece of a project's mark behind one of its lines, while a dragged
/// tab is over the project (`SupervisionProjectDropMark`); nothing behind
/// any other line.
struct SidebarProjectDropPiece: View {
    let line: SidebarItemID
    let carriedOver: CarriedOverProject?

    var body: some View {
        if let carriedOver, line.projectID == carriedOver.projectID {
            SupervisionProjectDropMark(
                isFirst: line == .header(carriedOver.projectID),
                isLast: line == carriedOver.lastLine,
                gapBelow: WeirLayout.Supervision.sessionRowSpacing
            )
            .transition(.opacity)
        }
    }
}

/// Drop a worktree's row on another of its project's to reorder them, and a
/// tab or a ⌥⌘-dragged pane on any row but a missing worktree's to move it
/// there. The project's own folder takes them too, and nothing is dropped
/// beside it.
struct SessionRowDropTarget: ViewModifier {
    let container: ContainerID
    /// `nil` for the scratch row, which belongs to no project.
    let project: Project?
    /// What a tab or pane dropped on the row does.
    let rowDrop: SidebarRowDrop
    @Environment(WeirDragState.self) private var dragState
    @Environment(\.weirAccent) private var accent

    private var window: WindowID {
        rowDrop.window
    }

    private var session: WorkspaceSession {
        rowDrop.session
    }

    func body(content: Content) -> some View {
        target(content)
            // The row a tab just landed on lights once, so the eye finds it
            // in a list that did not move.
            .overlay {
                if dragState.landing?.window == window, dragState.landing?.container == container {
                    RoundedRectangle(cornerRadius: WeirLayout.Supervision.sessionRowCornerRadius, style: .continuous)
                        .fill(accent.opacity(SupervisionTokens.dropTargetFillOpacity))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
    }

    @ViewBuilder
    private func target(_ content: Content) -> some View {
        let dropProject = project.map { SidebarDropProject(window: window, projectID: $0.id) }
        if let project, let worktreeID = container.worktreeID {
            content.reorderableDropTarget(
                targetID: SidebarDropTarget.row(container, in: window),
                acceptedPrefixes: [DragPrefix.tab, DragPrefix.pane, DragPrefix.worktree],
                assignsOnDrop: true,
                project: dropProject,
                isNoOp: { sourceID, position in
                    dragState.isCarryingToRow
                        ? rowDrop.refuses(sourceID, on: container)
                        : session.isNoOpDrop(of: sourceID, onWorktree: worktreeID, projectID: project.id, position: position)
                },
                onDrop: { prefix, sourceID, position in
                    if prefix != DragPrefix.worktree {
                        rowDrop.drop(prefix: prefix, sourceID, on: container)
                    } else if session.projectID(forWorktree: sourceID) == project.id {
                        session.reorderWorktree(projectID: project.id, sourceID: sourceID, target: worktreeID, position: position)
                    }
                }
            )
        } else {
            content.reorderableDropTarget(
                targetID: SidebarDropTarget.row(container, in: window),
                acceptedPrefixes: [DragPrefix.tab, DragPrefix.pane],
                assignsOnDrop: true,
                // The repository row is where a tab dropped on its project's
                // header goes, and says so while the header is under it.
                rowMark: project.map { .alsoUnder(targetID: SidebarDropTarget.header($0.id, in: window)) } ?? .own,
                project: dropProject,
                isNoOp: { sourceID, _ in rowDrop.refuses(sourceID, on: container) },
                onDrop: { prefix, sourceID, _ in rowDrop.drop(prefix: prefix, sourceID, on: container) }
            )
        }
    }
}

/// The names the sidebar's lines take as drop targets
/// (`reorderableDropTarget`). Each names the window too: every window lists
/// every project, and a drag marks only the sidebar it is dragged across.
enum SidebarDropTarget {
    static func header(_ projectID: UUID, in window: WindowID) -> String {
        "\(window.rawValue)-header-\(projectID)"
    }

    static func row(_ container: ContainerID, in window: WindowID) -> String {
        "\(window.rawValue)-session-\(container)"
    }
}
