// TitleBarMenuHost.swift
// Limpid — hangs the title bar's dropdowns, and the pane strip's "+" menu, over the window.

import AppKit
import SwiftUI

/// Draws the window's open dropdown (project ▾, worktree ▾, the Needs
/// Attention list, or the pane strip's "+") as a floating panel below its
/// control. A
/// popover's arrow, frame, and corners cannot be changed, so it could not
/// match the surface every dropdown shares; this host uses the one the
/// app's other floating panels share. A click elsewhere closes it, and so
/// does Escape, unless an approval card the list opened has the keyboard:
/// the card closes first.
struct TitleBarMenuHost: View {
    @Environment(ProjectWindowState.self) private var window
    @Environment(WorkspaceSession.self) private var session
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.locale) private var locale
    @Environment(\.limpidAccent) private var limpidAccent
    /// Set from the project dropdown; the sheet is presented here, so
    /// closing the dropdown does not take the sheet with it.
    @State private var settingsTarget: SettingsTarget?

    /// The project whose settings sheet is up, by its ID: what
    /// `.sheet(item:)` tells one sheet from the next by.
    private struct SettingsTarget: Identifiable {
        let id: UUID
    }

    /// Set from the project dropdown's, a sidebar header's, or the palette's
    /// Close Project…, and confirmed here for the same reason as the settings sheet.
    @State private var closingProject: RemoveProjectTarget?
    /// The window's height, which the settings sheet is sized from, as the
    /// keyboard shortcuts panel is: the window can be shorter than the
    /// sheet's preferred height.
    @State private var windowHeight: CGFloat = 0

    /// The list's heading and padding, above the rows that scroll: the
    /// heading's line, as tall as its Next Action button, and the padding
    /// around it.
    private static let listHeadingHeight = LimpidLayout.Supervision.needsAttentionHeadingTopInset
        + LimpidLayout.Supervision.secondaryButtonHeight
        + LimpidLayout.Supervision.needsAttentionHeadingBottomInset

    var body: some View {
        GeometryReader { geometry in
            FloatingPanelHost(
                request: window.titleBarMenu,
                width: window.titleBarMenu.map { Self.width(of: $0.menu) } ?? 0,
                style: .init(alignment: .leading, gap: window.titleBarMenu.map { Self.gap(of: $0.menu) } ?? 0, arrowInset: nil),
                onPointerPressedOutside: { window.titleBarMenu = nil },
                onKey: { key in
                    guard key.isEscape, !window.approvalCard.isFocused else { return false }
                    window.titleBarMenu = nil
                    return true
                },
                isAnchorPressLeftToAnchor: true,
                content: { menu($0, in: geometry) }
            )
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            windowHeight = height
        }
        // However it closed (Escape, its control, a click elsewhere, a
        // choice in it), the dropdown may have held the keyboard; what it
        // led to takes it, or else the terminal gets it back.
        .onChange(of: window.titleBarMenu?.id) { previous, current in
            if previous != nil, current == nil {
                // At once: anything but a terminal holding the keys is the
                // dropdown's own field or list, still fading out.
                KeyboardHandoff.returnToFocusedPane(
                    in: window.id,
                    session: session,
                    registry: registry,
                    keeper: .terminal,
                    timing: .now
                )
            }
        }
        // The palette's and the sidebar headers' Project Settings…,
        // shown here like the project ▾'s own, and their Close Project…,
        // confirmed like the project ▾'s. A header names its project; the
        // palette means the window's, and a window showing no project has
        // neither to show. Both stay in the window asked, even for a project
        // another window shows: they change the project's settings or close
        // it, not what that window shows or selects.
        .onWindowCommand(of: window) { command in
            switch command {
            case let .openProjectSettings(asked):
                if let projectID = asked ?? window.selection.shownProjectID, session.project(projectID) != nil {
                    settingsTarget = SettingsTarget(id: projectID)
                }
            case let .closeProject(asked):
                closingProject = Self.closeTarget(for: asked ?? window.selection.shownProjectID, in: session)
            default:
                return false
            }
            return true
        }
        // Close Project…'s confirmation, from the project ▾, a sidebar
        // header, or the palette.
        // Its removal moves each window that showed the project to another.
        .worktreeOperationAlerts(
            deletingWorktree: .constant(nil),
            forceDeleteWorktree: .constant(nil),
            removingProject: $closingProject,
            worktreeOperationError: .constant(nil)
        )
        .sheet(item: $settingsTarget) { target in
            ContainerSettingsSheet(
                projectID: target.id,
                height: ContainerSettingsSheet.height(forWindowHeight: windowHeight)
            )
            .environment(session)
            // Re-applied like the accent: macOS presents the sheet in a
            // detached window, and its text must follow the language
            // the window shows.
            .environment(\.locale, locale)
            .limpidAccentPropagated(limpidAccent)
        }
        .returnsKeyboardOnDismiss(
            isPresented: settingsTarget != nil,
            window: window.id,
            session: session,
            registry: registry
        )
    }

    @ViewBuilder
    private func menu(_ request: TitleBarMenuRequest, in geometry: GeometryProxy) -> some View {
        switch request.menu {
        case .project:
            ProjectDropdown(
                onOpenSettings: { settingsTarget = SettingsTarget(id: $0) },
                onCloseProject: { closingProject = Self.closeTarget(for: $0, in: session) },
                dismiss: close,
                maxHeight: room(below: request, in: geometry)
            )
        case .worktree:
            WorktreeDropdown(dismiss: close, maxHeight: room(below: request, in: geometry))
        case .needsAttention:
            NeedsAttentionListView(
                maxListHeight: listHeight(below: request.anchor, in: geometry),
                opening: request.needsAttentionOpening
            ) { action in
                close()
                action()
            }
        case let .addTab(container):
            AddTabMenu(container: container, dismiss: close)
        }
    }

    private func close() {
        window.titleBarMenu = nil
    }

    /// What Close Project… confirms: the project, while it is still there.
    static func closeTarget(for projectID: UUID?, in session: WorkspaceSession) -> RemoveProjectTarget? {
        guard let projectID, let project = session.project(projectID) else { return nil }
        return RemoveProjectTarget(projectID: project.id, name: project.name)
    }

    private static func width(of menu: TitleBarMenuRequest.Menu) -> CGFloat {
        switch menu {
        case .project, .worktree: LimpidLayout.Supervision.titleBarDropdownWidth
        case .needsAttention: LimpidLayout.Supervision.needsAttentionListWidth
        case .addTab: 300
        }
    }

    /// Between the control and the panel: a title bar dropdown hangs just
    /// under its control; the pane strip's "+" keeps its own air.
    private static func gap(of menu: TitleBarMenuRequest.Menu) -> CGFloat {
        switch menu {
        case .project, .worktree, .needsAttention: LimpidLayout.Supervision.titleBarDropdownGap
        case .addTab: LimpidLayout.Supervision.addTabMenuGap
        }
    }

    /// The list scrolls within what fits between its control and the
    /// window's bottom, so the last item is never below the window.
    private func listHeight(below anchor: CGRect, in geometry: GeometryProxy) -> CGFloat {
        let window = geometry.frame(in: .global)
        let available = window.maxY - anchor.maxY - Self.gap(of: .needsAttention)
            - LimpidLayout.floatingPanelWindowMargin - Self.listHeadingHeight
        return max(available, 120)
    }

    /// Returns the tallest the dropdown may be under its control: what a dropdown
    /// with items below its list (Close Project…, New Worktree…) caps
    /// the list to, so a short window keeps them in sight.
    private func room(below request: TitleBarMenuRequest, in geometry: GeometryProxy) -> CGFloat {
        FloatingPanelPlacement.roomBelow(
            anchor: request.anchor,
            containerMaxY: geometry.frame(in: .global).maxY,
            gap: Self.gap(of: request.menu),
            margin: LimpidLayout.floatingPanelWindowMargin
        )
    }
}
