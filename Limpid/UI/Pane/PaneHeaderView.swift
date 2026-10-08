// PaneHeaderView.swift
// Limpid — the one-line header above each pane of a split tab: what the
// pane is, what it is called, and what its agent is doing.
//
// The header sits above the terminal rather than over it, so the grid it
// draws is never covered; the terminal gives up the header's height
// instead. `PaneHeaderRules` decides when it shows and what it says; this
// view only lays that out and owns the rename, in place or, when the header
// is too narrow for a field, in a floating panel below it.

import AppKit
import SwiftUI

struct PaneHeaderView: View {
    let paneID: UUID
    /// The pane taking keystrokes, by the same reading `PaneContainerView`
    /// uses for its fade. The header does not fade with the terminal: it is
    /// what tells the panes apart, and a dimmed name is harder to find.
    let isFocused: Bool
    @Environment(WindowSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.displayScale) private var displayScale
    @Environment(PaneRenamePresentation.self) private var renamePresentation

    @State private var isEditing = false
    /// The name the header showed when the in-place edit began. The commit
    /// compares against it rather than the current label, which an agent
    /// can retitle mid-edit.
    @State private var editingShownName: String?
    /// The header's frame in global coordinates: its width decides whether
    /// a rename fits in place, and the floating field hangs below it.
    @State private var headerFrame: CGRect = .zero
    @State private var isHovering = false
    /// True from the moment the pointer moves with the button down until
    /// the gesture ends or is canceled, which is how a drag that AppKit
    /// took over still resets.
    @GestureState private var isPointerDragging = false
    /// Set once this drag has handed the pane to AppKit, so one gesture
    /// starts one dragging session.
    @State private var hasStartedPaneDrag = false

    /// The agent this pane's header speaks for, if any.
    private var runtime: AgentRuntimePresentation? {
        attention.headerRuntime(inPane: paneID)
    }

    /// Whether this pane is the one its tab shows zoomed.
    private var isZoomed: Bool {
        PaneHeaderRules.isZoomed(paneID, in: session.tab(containing: paneID))
    }

    /// The width a usable in-place field needs here, counting the prompt
    /// cache clock while this header draws one and the unzoom button while
    /// the pane is zoomed.
    private var inlineRenameThreshold: CGFloat {
        PaneHeaderMetrics.inlineRenameMinimumWidth(
            showsPromptCacheClock: attention.promptCacheMark(paneID: paneID) != nil,
            isZoomed: isZoomed
        )
    }

    /// Resolved in Core, where the prompt cache panel reads the same label,
    /// so the panel names this pane the way this header does.
    private var label: PaneHeaderLabel {
        attention.paneHeaderLabel(paneID: paneID, in: session)
    }

    /// The mark on the trailing edge, reduced the way the tab row reduces
    /// its panes. Hidden for states the tab row also leaves unmarked.
    private var stateSummary: AgentStateSummary? {
        guard let summary = attention.aggregateAgentStateSummary(inPane: paneID),
              summary.state.hasVisibleBadge
        else { return nil }
        return summary
    }

    var body: some View {
        let label = self.label
        let summary = stateSummary
        // The widest row that fits, so a narrow pane drops what it cannot
        // show rather than leaving an empty gap or cutting the menu at the
        // edge. The glyph and the menu always stay: the glyph says what the
        // pane is and the menu is how to act on it. While renaming the field
        // is what matters, so the name stays.
        ViewThatFits(in: .horizontal) {
            ForEach(PaneHeaderRules.forms(
                isEditing: isEditing,
                showsPromptCacheClock: attention.promptCacheMark(paneID: paneID) != nil
            ), id: \.self) { form in
                row(label: label, summary: summary, form: form)
            }
        }
        .padding(.horizontal, LimpidLayout.paneHeaderHorizontalPadding)
        // `minWidth: 0` holds the header to the pane's width when the pane
        // is narrower than the row's smallest layout. Without it the frame
        // grows to the row's width, the pane centers that wider header, and
        // the glyph slides left past the pane's edge; with it the row keeps
        // its leading edge.
        //
        // Not clipped. The split floor never lets a pane get narrower than
        // the glyph-and-menu form (`PaneHeaderMetrics.minimumWidth`), so
        // there is nothing to cut. And clipping a row that holds the
        // AppKit-backed menu makes SwiftUI put the whole row, with every
        // AppKit view drawn in it such as the cache clock's pointer tracker,
        // inside an AppKit clip view (`_NSGraphicsView`), for no gain.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: LimpidLayout.paneHeaderHeight)
        .background(background)
        .overlay(alignment: .bottom) {
            LimpidColor.paneHeaderDivider
                .frame(height: 1 / max(displayScale, 1))
        }
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { newFrame in
            headerFrame = newFrame
            renamePresentation.updateAnchor(paneID: paneID, anchor: newFrame)
            // Narrowed below a usable field mid-edit: the edit ends as a
            // click elsewhere ends it, by the keyboard going back to the
            // terminal, which commits what was typed.
            if PaneHeaderRules.shouldEndInlineRename(
                isEditing: isEditing,
                headerWidth: newFrame.width,
                threshold: inlineRenameThreshold
            ) {
                PaneActions.pullKeyboardFocus(to: paneID, registry: registry)
            }
        }
        // A floating field outlives nothing it renames: a pane closed, a tab
        // switched away, or a zoom elsewhere takes this header off screen,
        // and the field goes with it.
        .onDisappear {
            renamePresentation.headerDisappeared(paneID: paneID)
            // A header remounted mid-edit (a sibling closed, the setting
            // went off) drops its field without the edit ending, so the
            // keyboard would stay with a field that no longer exists.
            if isEditing {
                PaneRenameFocus.returnToTerminal(paneID: paneID, registry: registry)
            }
        }
        .onHover { isHovering = $0 }
        // Simultaneous, so the rename field's double-click is not held up
        // behind this tap and the focus change lands on the first click,
        // the way a click on the terminal itself does.
        .simultaneousGesture(
            TapGesture().onEnded {
                if !isEditing {
                    focusPane()
                }
            }
        )
        // Dragging the header picks the pane up, the same drag ⌥⌘ starts
        // from the terminal, where a plain drag has to stay a text
        // selection. The few points before it starts leave clicks, the
        // name's double-click, and the menu as they were; while renaming,
        // a drag selects text in the field instead, and while zoomed there
        // is no split beside the pane to drop it into.
        .simultaneousGesture(
            DragGesture(minimumDistance: LimpidLayout.paneDragThreshold)
                .updating($isPointerDragging) { _, state, _ in state = true }
                .onChanged { _ in startPaneDrag() },
            including: PaneHeaderRules.dragsPane(isEditing: isEditing, isZoomed: isZoomed) ? .all : .subviews
        )
        .onChange(of: isPointerDragging) { _, dragging in
            if !dragging {
                hasStartedPaneDrag = false
            }
        }
        .help(Text(verbatim: [label.name, label.agentName, label.detail].compactMap(\.self).joined(separator: " — ")))
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityDescription(label, summary: summary)))
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction { focusPane() }
        .accessibilityAction(named: Text("Rename Pane…")) { beginRename(label: label) }
        .accessibilityAction(named: zoomActionTitle) { performZoomAction() }
        // The ellipsis menu sits inside this single element, so its actions
        // are offered on the header itself as well.
        .accessibilityAction(named: Text("Move Pane to New Tab")) {
            TabActions.movePaneToNewTab(session, paneID: paneID)
        }
        .accessibilityAction(named: Text("Close Pane")) { onSurface { $0.onRequestCloseActivePane?() } }
        .promptCacheAccessibilityAction(attention.promptCacheMark(paneID: paneID)) { _ in
            // The header's own clock, or, in the narrowest form that draws
            // none, the tab row's.
            [.paneHeader(paneID: paneID)] + (session.tab(containing: paneID).map { [.tabRow(tabID: $0.id)] } ?? [])
        }
        // The terminal's "Rename Pane…" asks through the rename presentation,
        // because the menu lives on the AppKit surface and the field lives
        // here. Only a new ask counts, never one found pending on mount: the
        // menu offers the item only while this header is on screen, so an ask
        // still pending when a header mounts is one nobody took, and starting
        // it then would be a surprise.
        .onChange(of: renamePresentation.pendingRename) { _, pending in
            guard pending?.paneID == paneID, renamePresentation.takeRenameRequest(paneID: paneID) else { return }
            beginRename(label: label)
        }
        .onChange(of: isEditing) { wasEditing, editing in
            if wasEditing, !editing {
                editingShownName = nil
                PaneRenameFocus.returnToTerminal(paneID: paneID, registry: registry)
            }
        }
    }

    private func row(label: PaneHeaderLabel, summary: AgentStateSummary?, form: PaneHeaderForm) -> some View {
        HStack(spacing: LimpidLayout.paneHeaderItemSpacing) {
            // The tab row's identity glyphs, so a pane and a single-pane tab
            // running the same thing are marked the same way.
            Image(systemName: label.isAgent ? "bolt" : "terminal")
                .font(.system(size: LimpidLayout.paneHeaderGlyphFontSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: LimpidLayout.paneHeaderGlyphSlot, height: LimpidLayout.paneHeaderGlyphSlot)
                .accessibilityHidden(true)
            if form.showsName {
                InlineRenameField(
                    name: label.name,
                    isEditing: $isEditing,
                    font: .system(size: LimpidLayout.paneHeaderNameFontSize, weight: isFocused ? .semibold : .regular),
                    foregroundColor: isFocused ? .primary : .secondary,
                    onRename: { submitted in
                        session.commitPaneRename(
                            paneID,
                            submitted: submitted,
                            shownName: editingShownName ?? label.name
                        )
                    },
                    fillsWidth: false,
                    submitsEmptyName: true,
                    // Between the widths where the name shows and the width a
                    // usable field needs, a double-click has to float too.
                    onBeginRename: { beginRename(label: label) }
                )
                .accessibilityLabel(Text("Pane name"))
                .frame(minWidth: 0, idealWidth: LimpidLayout.paneHeaderNameFittingWidth, alignment: .leading)
                // The name keeps its width longest; the detail gives way first.
                .layoutPriority(1)
            }
            if form.showsDetail, let detail = label.detail {
                detailText(detail)
            }
            Spacer(minLength: LimpidLayout.paneHeaderItemSpacing)
            if form.showsPromptCacheClock {
                PromptCachePaneClock(paneID: paneID)
            }
            if form.showsMark, let summary {
                AgentStateMark(
                    state: summary.state,
                    isViewedFinished: summary.isViewedFinished,
                    tooltip: stateTooltip(for: summary.state)
                )
            }
            // In every form while zoomed, beside the menu: the way back to
            // the split, where the eye looks for the pane's own controls.
            if isZoomed {
                unzoomButton
            }
            actionsMenu(label: label)
        }
    }

    /// A wash over the pane's own background; see `paneHeaderFill`.
    private var background: some View {
        isFocused ? LimpidColor.paneHeaderFocusedFill : LimpidColor.paneHeaderFill
    }

    /// The detail truncates before the name does, and goes entirely once
    /// it cannot show a useful fragment, rather than leaving an ellipsis
    /// wedged between the name and the state mark.
    private func detailText(_ detail: String) -> some View {
        ViewThatFits(in: .horizontal) {
            styledDetail(detail)
            styledDetail(detail)
                .frame(minWidth: 0, idealWidth: LimpidLayout.paneHeaderDetailFittingWidth, alignment: .leading)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private func styledDetail(_ detail: String) -> some View {
        Text(verbatim: detail)
            .font(.system(size: LimpidLayout.paneHeaderDetailFontSize))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.head)
    }

    /// Hover text for the state mark: the state, then what the agent is
    /// doing when the badge says, as the tab row phrases a single pane.
    private func stateTooltip(for state: AgentState) -> String {
        var pieces = [state.localizedLabel]
        if let detail = runtime?.badge.detail, !detail.isEmpty {
            pieces.append("· \(detail)")
        }
        return pieces.joined(separator: " ")
    }

    private func accessibilityDescription(_ label: PaneHeaderLabel, summary: AgentStateSummary?) -> String {
        var pieces = [label.name]
        if let agentName = label.agentName {
            pieces.append(agentName)
        }
        if let detail = label.detail {
            pieces.append(detail)
        }
        if let summary {
            pieces.append(summary.state.accessibilityLabel(isViewedFinished: summary.isViewedFinished))
        }
        // The header is one element, so the clock inside it is heard here.
        if let mark = attention.promptCacheMark(paneID: paneID) {
            pieces.append(mark.spokenStatus)
        }
        return pieces.joined(separator: ", ")
    }

    /// Start a rename from the name's double-click, the menu, the
    /// terminal's context menu, or VoiceOver: in place when the header has
    /// room for a usable field, otherwise in a floating field under the
    /// header (`PaneHeaderRules.renameStyle`). Either way the commit
    /// compares against the name shown now, when the edit begins.
    private func beginRename(label: PaneHeaderLabel) {
        switch PaneHeaderRules.renameStyle(headerWidth: headerFrame.width, threshold: inlineRenameThreshold) {
        case .inline:
            editingShownName = label.name
            isEditing = true
        case .floating:
            renamePresentation.open(paneID: paneID, name: label.name, anchor: headerFrame)
        }
    }

    /// The header's zoom item: zoom this pane, or, while it is zoomed, go
    /// back to the split.
    private var zoomAction: PaneZoomAction {
        PaneHeaderRules.zoomAction(isZoomed: isZoomed)
    }

    private var zoomActionTitle: Text {
        switch zoomAction {
        case .zoom: Text("Zoom Pane")
        case .unzoom: Text("Unzoom Pane")
        }
    }

    private var zoomActionSymbol: String {
        switch zoomAction {
        case .zoom: "arrow.up.left.and.arrow.down.right"
        case .unzoom: "arrow.down.right.and.arrow.up.left"
        }
    }

    /// Zooms this pane, focusing it first so it is the one zoomed, or goes
    /// back to the split.
    private func performZoomAction() {
        switch zoomAction {
        case .zoom:
            focusPane()
            PaneActions.toggleZoom(session)
        case .unzoom:
            if let tab = session.tab(containing: paneID) {
                PaneActions.unzoom(session, tabID: tab.id)
            }
        }
    }

    /// The way back from zoom, in a slot the size of the menu's beside it.
    private var unzoomButton: some View {
        Button {
            performZoomAction()
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: LimpidLayout.paneHeaderMenuFontSize, weight: .semibold))
                .foregroundStyle(isHovering ? .secondary : .tertiary)
                .frame(width: LimpidLayout.paneHeaderMenuSlot, height: LimpidLayout.paneHeaderMenuSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Text("Unzoom Pane"))
        .accessibilityLabel(Text("Unzoom Pane"))
    }

    /// What can be done to this pane alone, reachable without knowing the
    /// terminal's right-click menu is there. Splitting is left out: the
    /// toolbar and ⌘D already split the focused pane, and a click on the
    /// header focuses it. Always drawn, so the state mark beside it never
    /// moves, and quiet until the pointer is on the header.
    private func actionsMenu(label: PaneHeaderLabel) -> some View {
        Menu {
            Button {
                beginRename(label: label)
            } label: {
                Label("Rename Pane…", systemImage: "pencil")
            }
            Divider()
            Button {
                performZoomAction()
            } label: {
                Label {
                    zoomActionTitle
                } icon: {
                    Image(systemName: zoomActionSymbol)
                }
            }
            Divider()
            Button {
                TabActions.movePaneToNewTab(session, paneID: paneID)
            } label: {
                Label("Move Pane to New Tab", systemImage: "rectangle.split.2x1")
            }
            Divider()
            Button(role: .destructive) {
                onSurface { $0.onRequestCloseActivePane?() }
            } label: {
                Label("Close Pane", systemImage: "xmark.square")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: LimpidLayout.paneHeaderMenuFontSize, weight: .semibold))
                .foregroundStyle(isHovering ? .secondary : .tertiary)
                .frame(width: LimpidLayout.paneHeaderMenuSlot, height: LimpidLayout.paneHeaderMenuSlot)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Pane actions"))
        .accessibilityLabel(Text("Pane actions"))
    }

    /// Runs one of the terminal's own pane actions. Those act on the focused
    /// pane, as they do from the right-click menu, where the click has
    /// already focused it; from the header we focus it first.
    private func onSurface(_ action: (SurfaceView) -> Void) {
        focusPane()
        if let view = registry.view(for: paneID) {
            action(view)
        }
    }

    /// Hands the pane to the terminal's own drag, which carries it to the
    /// tab column or another pane exactly as the ⌥⌘ drag does. It needs the
    /// mouse event AppKit is delivering, which is the current one while the
    /// gesture updates.
    private func startPaneDrag() {
        guard PaneHeaderRules.dragsPane(isEditing: isEditing, isZoomed: isZoomed),
              !hasStartedPaneDrag,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged,
              let view = registry.view(for: paneID)
        else { return }
        hasStartedPaneDrag = true
        focusPane()
        view.beginPaneDrag(with: event)
    }

    /// Focus this pane the way a click on its terminal does: the split
    /// tree's focused leaf for the model, first responder for the keyboard.
    private func focusPane() {
        if let tab = session.tab(containing: paneID), tab.splitTree.focusedLeafID != paneID {
            session.update(tab.id) { $0.splitTree.focusedLeafID = paneID }
        }
        PaneActions.pullKeyboardFocus(to: paneID, registry: registry)
    }
}
