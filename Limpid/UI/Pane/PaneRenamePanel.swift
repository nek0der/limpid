// PaneRenamePanel.swift
// Limpid — the floating rename field for a pane whose header is too narrow
// to edit in place. Drawn at the scene root by `FloatingPanelLayer`, so it
// can be wider than the pane and overlap its neighbors; see
// `PaneRenamePresentation` for the request it draws.

import AppKit
import SwiftUI

/// Hosts the floating field at scene root, under the header that asked for
/// it, or above it near the window's bottom. Empty regions pass clicks
/// through to the window, as `PRHoverCardHost`'s do.
///
/// No panel watcher: the field is the whole of the panel's keyboard and
/// click handling. Return commits, Escape cancels (`onExitCommand`), and a
/// click outside commits through the field's own monitor, once. A second
/// watcher for Escape or that click would compete with it.
struct PaneRenamePanelHost: View {
    @Environment(PaneRenamePresentation.self) private var presentation
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.surfaceRegistry) private var registry

    var body: some View {
        FloatingPanelHost(
            request: presentation.request,
            width: LimpidLayout.paneRenamePanelWidth,
            style: .underHeader,
            content: { request in
                PaneRenamePanel(
                    request: request,
                    isEditing: isEditing(request),
                    onRename: { submitted in
                        session.commitPaneRename(request.paneID, submitted: submitted, shownName: request.name)
                    }
                )
            }
        )
    }

    /// True for as long as `request` is the open one. The field clears it
    /// when it ends, which finishes the request and hands the keyboard back
    /// to the pane's terminal.
    private func isEditing(_ request: PaneRenamePresentation.Request) -> Binding<Bool> {
        Binding(
            get: { presentation.request?.id == request.id },
            set: { editing in
                guard !editing, let finished = presentation.finish(requestID: request.id) else { return }
                KeyboardHandoff.returnToTerminal(
                    paneID: finished.paneID,
                    registry: registry,
                    keeper: .terminalOrTextField,
                    timing: .nextTurn
                )
            }
        )
    }
}

/// The panel's body: a caption and the field. The field is the same
/// `InlineRenameField` the header and the tab rows use, so Return commits,
/// Escape cancels, and a click elsewhere commits here too. The host draws
/// the surface around it.
private struct PaneRenamePanel: View {
    let request: PaneRenamePresentation.Request
    let isEditing: Binding<Bool>
    let onRename: (String) -> Void
    @Environment(\.limpidAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: LimpidLayout.paneRenamePanelSpacing) {
            Text("Pane name")
                .font(LimpidFont.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            InlineRenameField(
                name: request.name,
                isEditing: isEditing,
                font: .supervision(LimpidLayout.paneRenameFieldFontSize),
                foregroundColor: .primary,
                onRename: onRename,
                submitsEmptyName: true,
                fieldName: "Pane name",
                // The box drawn here is the field's edge, so the field keeps
                // to it rather than standing in a well of its own.
                editingStyle: .boxed
            )
            .padding(.vertical, LimpidLayout.paneRenameFieldVerticalPadding)
            .padding(.horizontal, LimpidLayout.paneRenameFieldHorizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: LimpidLayout.paneRenameFieldCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LimpidLayout.paneRenameFieldCornerRadius, style: .continuous)
                    .stroke(accent, lineWidth: 1)
            )
        }
        .padding(LimpidLayout.floatingPanelPadding)
    }
}
