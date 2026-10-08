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
    @Environment(WindowSession.self) private var session
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
                PaneRenameFocus.returnToTerminal(paneID: finished.paneID, registry: registry)
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
                font: .system(size: LimpidLayout.paneRenameFieldFontSize),
                foregroundColor: .primary,
                onRename: onRename,
                submitsEmptyName: true
            )
            .accessibilityLabel(Text("Pane name"))
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

/// Where the keyboard goes once a pane rename ends, in the header or in the
/// floating panel: back to the pane's terminal, unless the edit ended
/// because the user went somewhere else. A click on another pane ends it
/// too, and by the time this runs that pane already holds the keyboard; so
/// does another field the click landed in. Deferred a tick so AppKit has
/// settled who owns first responder after the field is torn down.
@MainActor
enum PaneRenameFocus {
    static func returnToTerminal(paneID: UUID, registry: any SurfaceViewProviding) {
        DispatchQueue.main.async {
            guard let view = registry.view(for: paneID), let window = view.window else { return }
            switch window.firstResponder {
            case is SurfaceView:
                return
            case let editor as NSText where (editor.delegate as? NSView)?.window != nil:
                return
            default:
                window.makeFirstResponder(view)
            }
        }
    }
}
