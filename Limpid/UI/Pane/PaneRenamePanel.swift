// PaneRenamePanel.swift
// Limpid — the floating rename field for a pane whose header is too narrow
// to edit in place. Drawn at the scene root by `ContentView`, so it can be
// wider than the pane and overlap its neighbors; see
// `PaneRenamePresentation` for the request it draws.

import AppKit
import SwiftUI

/// Hosts the floating field at scene root, under the header that asked for
/// it, or above it near the window's bottom. Empty regions pass clicks
/// through to the window, as `PRHoverCardHost`'s do; a click outside the
/// field still reaches the field's own monitor, which commits it.
struct PaneRenamePanelHost: View {
    @Environment(PaneRenamePresentation.self) private var presentation
    @Environment(WindowSession.self) private var session
    @Environment(\.surfaceRegistry) private var registry

    /// The panel's measured height, for keeping it inside the window. Zero
    /// until the first layout, which places it below the header.
    @State private var panelHeight: CGFloat = 0

    var body: some View {
        GeometryReader { overlayGeo in
            if let request = presentation.request {
                let overlayOrigin = overlayGeo.frame(in: .global).origin
                let anchor = request.anchor.offsetBy(dx: -overlayOrigin.x, dy: -overlayOrigin.y)
                let width = LimpidLayout.paneRenamePanelWidth
                let origin = PaneRenamePresentation.panelOrigin(
                    anchor: anchor,
                    panelSize: CGSize(width: width, height: panelHeight),
                    container: overlayGeo.size,
                    margin: LimpidLayout.floatingPanelWindowMargin,
                    gap: LimpidLayout.paneRenamePanelAnchorGap
                )
                PaneRenamePanel(
                    request: request,
                    isEditing: isEditing(request),
                    onRename: { submitted in
                        session.commitPaneRename(request.paneID, submitted: submitted, shownName: request.name)
                    }
                )
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                .offset(x: origin.x, y: origin.y)
                .id(request.id)
            }
        }
        .ignoresSafeArea()
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

/// The panel itself: a caption and the field. The field is the same
/// `InlineRenameField` the header and the tab rows use, so Return commits,
/// Escape cancels, and a click elsewhere commits here too.
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
        .padding(LimpidLayout.paneRenamePanelPadding)
        .floatingPanelSurface(cornerRadius: LimpidLayout.floatingPanelCornerRadius)
        .pointerStyle(.default)
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
