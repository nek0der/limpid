// PaneHeaderView.swift
// Weir — the one-line header above every pane: what the pane is, what it is called, what its agent is doing,
// and which model it runs and how freely.
//
// The header sits above the terminal rather than over it, so the grid it
// draws is never covered; the terminal gives up the header's height
// instead. `PaneHeaderRules` decides what it says; this
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
    @Environment(WorkspaceSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.conversationIdentities) private var conversationIdentities
    @Environment(\.turnHistory) private var turnHistory
    @Environment(\.displayScale) private var displayScale
    @Environment(PaneRenamePresentation.self) private var renamePresentation
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.locale) private var locale
    /// The window this header is drawn in, which its actions act in: the
    /// same window as the pane's own view and its right-click.
    @Environment(ProjectWindowState.self) private var window

    @State private var isEditing = false
    /// The name the header showed when the in-place edit began. The commit
    /// compares against it rather than the current label, which an agent
    /// can retitle mid-edit.
    @State private var editingShownName: String?
    /// The header's frame in global coordinates: its width decides whether
    /// a rename fits in place, and the floating field hangs below it.
    @State private var headerFrame: CGRect = .zero
    @State private var isHovering = false
    /// The pointer is on the chip of hidden panes. The header's own tap
    /// focuses this pane and runs alongside the chip's, which goes to another:
    /// in either order, this one taking focus back would undo the chip.
    @State private var isHoveringHiddenPanes = false
    /// True from the moment the pointer moves with the button down until
    /// the gesture ends or is canceled, which is how a drag that AppKit
    /// took over still resets.
    @GestureState private var isPointerDragging = false
    /// Set once this drag has handed the pane to AppKit, so one gesture
    /// starts one dragging session.
    @State private var hasStartedPaneDrag = false

    /// Whether the pane shares its tab: only then can it be zoomed or moved
    /// to a tab of its own. A pane alone in its tab has a header too.
    private var isSplit: Bool {
        PaneHeaderRules.menuZoomAction(for: paneID, in: session.tab(containing: paneID)) != nil
    }

    /// Whether this pane is the one its tab shows zoomed.
    private var isZoomed: Bool {
        PaneHeaderRules.isZoomed(paneID, in: session.tab(containing: paneID))
    }

    /// The width a usable in-place field needs here, counting the prompt
    /// cache clock while this header draws one, the warning's symbol while
    /// the agent runs without asking, and the unzoom button while the pane
    /// is zoomed.
    private var inlineRenameThreshold: CGFloat {
        PaneHeaderMetrics.inlineRenameMinimumWidth(
            showsPromptCacheClock: attention.promptCacheMark(paneID: paneID) != nil,
            showsWarning: label.showsWarning,
            isZoomed: isZoomed
        )
    }

    /// Resolved in Core, where the prompt cache panel reads the same label,
    /// so the panel names this pane the way this header does.
    private var label: PaneHeaderLabel {
        attention.paneHeaderLabel(paneID: paneID, in: session, locale: locale)
    }

    /// What the pane's conversation has used, its kept turns together; `nil`
    /// while none has a count, or while the header cannot tell which run it
    /// speaks for. Read here rather than in the label, which every surface
    /// that names a pane reads and none of the others needs this from.
    private func usage(of label: PaneHeaderLabel) -> TurnUsage? {
        guard !label.settingsAreAmbiguous, let conversation = label.conversation else { return nil }
        return turnHistory.flatMap { TurnUsage.total(of: $0.turns(of: conversation)) }
    }

    private func withTokens(_ label: PaneHeaderLabel, usage: TurnUsage?) -> PaneHeaderLabel {
        var label = label
        label.tokens = usage.map { ChangesPanelText.tokenCount($0, locale: locale) }
        return label
    }

    /// The conversation's color, as its tab and its cards wear it; `nil` for
    /// a worktree of one conversation and for a scratch tab. Read here rather
    /// than in the pane area: what decides the colors follows every turn, and
    /// this body draws the header alone, where the area's would draw the
    /// terminal again.
    private func identity(of label: PaneHeaderLabel) -> Int? {
        guard let conversation = label.conversation, let tab = session.tab(containing: paneID) else { return nil }
        return conversationIdentities?.identities(in: tab.container)[conversation]
    }

    /// The panes this one stands in front of while zoomed.
    private var hiddenPanes: PaneHeaderHiddenPanes? {
        PaneHeaderRules.hiddenPanes(behind: paneID, in: session.tab(containing: paneID), items: attentionQueue.queue.items)
    }

    /// The mark on the trailing edge (`PaneHeaderRules.mark`).
    private var mark: PaneHeaderMark? {
        PaneHeaderRules.mark(
            paneID: paneID,
            items: attentionQueue.queue.items,
            runtimes: attention.allRuntimes,
            session: session
        )
    }

    var body: some View {
        let usage = usage(of: self.label)
        let label = withTokens(self.label, usage: usage)
        let mark = self.mark
        let identity = identity(of: label)
        let hiddenPanes = self.hiddenPanes
        // The widest row that fits, so a narrow pane drops what it cannot
        // show rather than leaving an empty gap or cutting the menu at the
        // edge. The kind's mark and the menu always stay: the mark says what the
        // pane is and the menu is how to act on it. While renaming the field
        // is what matters, so the name stays.
        ViewThatFits(in: .horizontal) {
            ForEach(PaneHeaderRules.forms(
                isEditing: isEditing,
                showsPromptCacheClock: attention.promptCacheMark(paneID: paneID) != nil
            ), id: \.self) { form in
                row(label: label, mark: mark, identity: identity, hiddenPanes: hiddenPanes, form: form)
            }
        }
        .padding(.horizontal, WeirLayout.paneHeaderHorizontalPadding)
        // `minWidth: 0` holds the header to the pane's width when the pane
        // is narrower than the row's smallest layout. Without it the frame
        // grows to the row's width, the pane centers that wider header, and
        // the kind's mark slides left past the pane's edge; with it the row keeps
        // its leading edge.
        //
        // Not clipped. The split floor never lets a pane get narrower than
        // the mark-and-menu form (`PaneHeaderMetrics.minimumWidth`), so
        // there is nothing to cut. And clipping a row that holds the
        // AppKit-backed menu makes SwiftUI put the whole row, with every
        // AppKit view drawn in it such as the cache clock's pointer tracker,
        // inside an AppKit clip view (`_NSGraphicsView`), for no gain.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: WeirLayout.paneHeaderHeight)
        .background(background)
        .overlay(alignment: .bottom) {
            WeirColor.paneHeaderDivider
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
            // A header remounted mid-edit (a sibling closed) drops its field without the edit ending, so
            // the keyboard would stay with a field that no longer exists.
            if isEditing {
                KeyboardHandoff.returnToTerminal(paneID: paneID, registry: registry, keeper: .terminalOrTextField, timing: .nextTurn)
            }
        }
        // Marks the conversation's cards while the pointer rests here.
        .conversationHover(
            label.conversation,
            surface: .paneHeader(paneID),
            identity: identity,
            mark: .paneHeader
        ) { isHovering = $0 }
        // Simultaneous, so the rename field's double-click is not held up
        // behind this tap and the focus change lands on the first click,
        // the way a click on the terminal itself does.
        .simultaneousGesture(
            TapGesture().onEnded {
                if !isEditing, !isHoveringHiddenPanes {
                    focusPane()
                }
            }
        )
        // Dragging the header picks the pane up, the same drag ⌥⌘ starts
        // from the terminal, where a plain drag has to stay a text
        // selection. The few points before it starts leave clicks and the
        // name's double-click as they were. The "⋯" menu opens on mouse-down
        // and its tracking takes the rest of the press, so neither this drag
        // nor the tap above starts from it. While renaming, a drag selects
        // text in the field instead, and while zoomed there is no split
        // beside the pane to drop it into.
        .simultaneousGesture(
            DragGesture(minimumDistance: WeirLayout.paneDragThreshold)
                .updating($isPointerDragging) { _, state, _ in state = true }
                .onChanged { _ in startPaneDrag() },
            including: PaneHeaderRules.dragsPane(isEditing: isEditing, isZoomed: isZoomed) ? .all : .subviews
        )
        .onChange(of: isPointerDragging) { _, dragging in
            if !dragging {
                hasStartedPaneDrag = false
            }
        }
        .help(Text(verbatim: hoverText(label, usage: usage)))
        .accessibilityElement(children: isEditing ? .contain : .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityDescription(label, usage: usage, mark: mark)))
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction { focusPane() }
        .accessibilityAction(named: Text("Rename Pane…")) { beginRename(label: label) }
        // The ellipsis menu sits inside this single element, so its actions
        // are offered on the header itself as well, and only those the menu
        // offers: a lone pane has no split to zoom out of or leave.
        .accessibilityActions {
            if isSplit {
                Button(zoomActionTitle) { performZoomAction() }
                Button("Move Pane to New Tab") { movePaneToNewTab() }
            }
            if let hiddenPanes {
                Button {
                    goToHiddenPane(hiddenPanes)
                } label: {
                    Text(verbatim: PaneHiddenPanesText.line(hiddenPanes, locale: locale))
                }
            }
        }
        .accessibilityAction(named: Text("Close Pane")) { onSurface { $0.onRequestCloseActivePane?() } }
        .promptCacheAccessibilityAction(attention.promptCacheMark(paneID: paneID)) { _ in
            // The header's own clock, or, in the narrowest form that draws
            // none, the tab row's.
            [.paneHeader(paneID: paneID)] + (session.tab(containing: paneID).map { [.tabRow(tabID: $0.id)] } ?? [])
        }
        // The terminal's "Rename Pane…" asks through the rename presentation,
        // because the menu lives on the AppKit surface and the field lives
        // here. Only a new ask counts, never one found pending on mount: an ask
        // still pending when a header mounts is one nobody took, and starting
        // it then would be a surprise.
        .onChange(of: renamePresentation.pendingRename) { _, pending in
            guard pending?.paneID == paneID, renamePresentation.takeRenameRequest(paneID: paneID) else { return }
            beginRename(label: label)
        }
        .onChange(of: isEditing) { wasEditing, editing in
            if wasEditing, !editing {
                editingShownName = nil
                KeyboardHandoff.returnToTerminal(paneID: paneID, registry: registry, keeper: .terminalOrTextField, timing: .nextTurn)
            }
        }
    }

    private func row(
        label: PaneHeaderLabel,
        mark: PaneHeaderMark?,
        identity: Int?,
        hiddenPanes: PaneHeaderHiddenPanes?,
        form: PaneHeaderForm
    ) -> some View {
        HStack(spacing: WeirLayout.paneHeaderItemSpacing) {
            kindMark(label: label, identity: identity, form: form)
            if form.showsName {
                InlineRenameField(
                    name: label.name,
                    isEditing: $isEditing,
                    font: .supervision(WeirLayout.paneHeaderNameFontSize, weight: isFocused ? .semibold : .regular),
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
                    onBeginRename: { beginRename(label: label) },
                    fieldName: "Pane name"
                )
                .accessibilityLabel(Text("Pane name"))
                .frame(minWidth: 0, idealWidth: WeirLayout.paneHeaderNameFittingWidth, alignment: .leading)
                // The name keeps its width longest; the detail gives way first.
                .layoutPriority(1)
            }
            if form.showsDetail, let detail = label.detail {
                detailText(detail)
            }
            Spacer(minLength: WeirLayout.paneHeaderItemSpacing)
            if form.showsSettings, let hiddenPanes {
                hiddenPanesChip(hiddenPanes)
            }
            // Kept for as long as the state mark is: in words while the row
            // has room for the model, else as the symbol alone.
            if form.showsMark, label.showsWarning {
                warning(inWords: form.showsSettings, isAmbiguous: label.settingsAreAmbiguous)
            }
            if form.showsSettings, let settings = label.settingsText(
                tokens: form.showsTokens ? label.tokens : nil,
                locale: locale
            ) {
                settingsText(settings)
            }
            if form.showsPromptCacheClock {
                PromptCachePaneClock(paneID: paneID)
            }
            if form.showsMark, let mark {
                AgentStateMark(kind: StateGlyph.Kind(mark.glyph), tooltip: stateTooltip(for: mark))
            }
            // In every form while zoomed, beside the menu: the way back to
            // the split, where the eye looks for the pane's own controls.
            if isZoomed {
                unzoomButton
            }
            actionsMenu(label: label)
        }
    }

    /// Who runs in the pane, as its tab and its cards mark it: the agent's
    /// badge, led by its conversation's color, or a shell's prompt. VoiceOver
    /// hears the agent in the header's label.
    @ViewBuilder
    private func kindMark(label: PaneHeaderLabel, identity: Int?, form: PaneHeaderForm) -> some View {
        if let kind = label.agentKind {
            ConversationIdentityLead(identity: form.showsIdentity(isEditing: isEditing) ? identity : nil) {
                SessionAgentBadge(
                    badge: .agent(kind),
                    text: SessionRowFactText.badge(.agent(kind), locale: locale),
                    size: .regular
                )
            }
        } else {
            ShellPromptBadge()
        }
    }

    /// What the zoom hides ("1 other pane · Needs approval"), which goes to
    /// the pane that most needs the person.
    private func hiddenPanesChip(_ hidden: PaneHeaderHiddenPanes) -> some View {
        Button {
            goToHiddenPane(hidden)
        } label: {
            Text(verbatim: PaneHiddenPanesText.line(hidden, locale: locale))
                .font(.supervision(WeirLayout.paneHeaderDetailFontSize, weight: hidden.glyph == nil ? .regular : .medium))
                .foregroundStyle(hidden.glyph.textColor)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringHiddenPanes = $0 }
        // A narrowing pane drops the chip under the pointer with no final
        // leave, which would keep the header's tap from focusing the pane.
        .onDisappear { isHoveringHiddenPanes = false }
    }

    private func goToHiddenPane(_ hidden: PaneHeaderHiddenPanes) {
        guard let tab = session.tab(containing: paneID) else { return }
        PaneActions.activateAndFocus(session, registry: registry, tabID: tab.id, paneID: hidden.lead, in: window.id, intent: .person)
    }

    /// A wash over the pane's own background; see `paneHeaderFill`.
    private var background: some View {
        isFocused ? WeirColor.paneHeaderFocusedFill : WeirColor.paneHeaderFill
    }

    /// The detail truncates before the name does, and goes entirely once
    /// it cannot show a useful fragment, rather than leaving an ellipsis
    /// wedged between the name and the state mark.
    private func detailText(_ detail: String) -> some View {
        ViewThatFits(in: .horizontal) {
            styledDetail(detail)
            styledDetail(detail)
                .frame(minWidth: 0, idealWidth: WeirLayout.paneHeaderDetailFittingWidth, alignment: .leading)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// The settings and the tokens. Never truncated: a row without room for
    /// them takes the next narrower form, which leaves the tokens out first.
    private func settingsText(_ settings: String) -> some View {
        Text(verbatim: settings)
            .font(.supervision(WeirLayout.paneHeaderDetailFontSize))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// We pair warnings about permissions or unavailable settings with a
    /// symbol and, when space allows, text so color never carries their
    /// meaning alone.
    private func warning(inWords: Bool, isAmbiguous: Bool) -> some View {
        HStack(spacing: WeirLayout.paneHeaderItemSpacing / 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.supervision(WeirLayout.paneHeaderWarningFontSize, weight: .semibold))
                .frame(width: WeirLayout.paneHeaderWarningSlot, height: WeirLayout.paneHeaderWarningSlot)
            if inWords {
                Text(isAmbiguous ? PaneHeaderLabel.unavailableSettings : AgentPermissionMode.bypassPermissions.spokenName)
                    .font(.supervision(WeirLayout.paneHeaderDetailFontSize, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(SupervisionTokens.waitingText.color)
        .fixedSize()
    }

    private func styledDetail(_ detail: String) -> some View {
        Text(verbatim: detail)
            .font(.supervision(WeirLayout.paneHeaderDetailFontSize))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .supervisionTruncation(.pathTitle)
    }

    /// Hover text for the state mark: the glyph's name, then what the
    /// agent is doing when the badge says.
    private func stateTooltip(for mark: PaneHeaderMark) -> String {
        AgentStatusText.pane(name: StateGlyph.Kind(mark.glyph).name.resolved(in: locale), detail: mark.detail, locale: locale)
    }

    /// The name, the agent, the directory, then the settings in
    /// full, which the row shortens or leaves out as it narrows.
    private func hoverText(_ label: PaneHeaderLabel, usage: TurnUsage?) -> String {
        ([label.name, label.agentName, label.detail] + settingsDescription(label, usage: usage))
            .compactMap(\.self)
            .joined(separator: " — ")
    }

    /// The model, the effort, the mode, and the exact tokens as the hover text
    /// and VoiceOver say them. The default mode is said here too, unlike in
    /// the row: a reader asking what the agent may do is told.
    private func settingsDescription(_ label: PaneHeaderLabel, usage: TurnUsage?) -> [String] {
        if label.settingsAreAmbiguous {
            return [PaneHeaderLabel.unavailableSettings.resolved(in: locale)]
        }
        let effort = label.effort.map { effort in
            LocalizedStringResource(
                "paneHeader.effort",
                defaultValue: "Effort: \(effort)",
                comment: "Pane header's hover text and VoiceOver: how hard the model reasons; argument: the agent's word, as in high"
            ).resolved(in: locale)
        }
        let tokens = usage.map { ChangesPanelText.tokenTotal($0, isExact: true, locale: locale) }
        return [label.model, effort, label.permissionMode?.spokenName.resolved(in: locale), tokens].compactMap(\.self)
    }

    private func accessibilityDescription(_ label: PaneHeaderLabel, usage: TurnUsage?, mark: PaneHeaderMark?) -> String {
        var pieces = [label.name]
        if let agentName = label.agentName {
            pieces.append(agentName)
        }
        if let detail = label.detail {
            pieces.append(detail)
        }
        pieces += settingsDescription(label, usage: usage)
        // The mark's own name, as the glyph reads it everywhere.
        if let mark {
            pieces.append(StateGlyph.Kind(mark.glyph).name.resolved(in: locale))
        }
        // The header is one element, so the clock inside it is heard here.
        if let mark = attention.promptCacheMark(paneID: paneID) {
            pieces.append(mark.spokenStatus.resolved(in: locale))
        }
        return AgentStatusText.spokenList(pieces, locale: locale)
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

    private var zoomActionTitle: LocalizedStringResource {
        switch zoomAction {
        case .zoom: "Zoom Pane"
        case .unzoom: "Unzoom Pane"
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
            PaneActions.toggleZoom(session, in: window.id)
        case .unzoom:
            if let tab = session.tab(containing: paneID) {
                PaneActions.unzoom(session, tabID: tab.id, in: window.id, intent: .person)
            }
        }
    }

    /// Moves this pane to a tab of its own, in the window that draws it.
    private func movePaneToNewTab() {
        TabActions.movePaneToNewTab(session, paneID: paneID, in: window.id, intent: .person)
    }

    /// The way back from zoom, in a slot the size of the menu's beside it.
    private var unzoomButton: some View {
        Button {
            performZoomAction()
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.supervision(WeirLayout.paneHeaderMenuFontSize, weight: .semibold))
                .foregroundStyle(isHovering ? .secondary : .tertiary)
                .frame(width: WeirLayout.paneHeaderMenuSlot, height: WeirLayout.paneHeaderMenuSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(Text("Unzoom Pane"))
        .accessibilityLabel(Text("Unzoom Pane"))
    }

    /// What can be done to this pane alone, reachable without knowing the
    /// terminal's right-click menu is there. Splitting is left out: the
    /// Pane menu and ⌘D already split the focused pane, and a click on the
    /// header focuses it. Always drawn, so the state mark beside it never
    /// moves, and quiet until the pointer is on the header.
    private func actionsMenu(label: PaneHeaderLabel) -> some View {
        PopUpMenuButton(title: "Pane actions") {
            actionsMenuEntries(label: label)
        } label: {
            Image(systemName: "ellipsis")
                .font(.supervision(WeirLayout.paneHeaderMenuFontSize, weight: .semibold))
                .foregroundStyle(isHovering ? .secondary : .tertiary)
                .frame(width: WeirLayout.paneHeaderMenuSlot, height: WeirLayout.paneHeaderMenuSlot)
                .contentShape(Rectangle())
        }
        .fixedSize()
    }

    /// Built when the menu opens, so the zoom item and the shortcuts are the
    /// ones current then. Zoom and Close show the keys that do the same to
    /// the focused pane, which these items make this one first.
    private func actionsMenuEntries(label: PaneHeaderLabel) -> [PopUpMenuEntry] {
        let keyboard = settingsStore.settings.keyboard
        // A lone pane has no split to zoom out of or leave, so its
        // menu holds only what can be done to it.
        let splitEntries: [PopUpMenuEntry] = isSplit ? [
            .item(PopUpMenuItem(
                title: zoomActionTitle,
                systemImage: zoomActionSymbol,
                shortcut: MenuCommand.togglePaneZoom.shortcut(in: keyboard)
            ) {
                performZoomAction()
            }),
            .separator,
            .item(PopUpMenuItem(title: "Move Pane to New Tab", systemImage: "rectangle.split.2x1") {
                movePaneToNewTab()
            }),
            .separator
        ] : []
        return [
            .item(PopUpMenuItem(title: "Rename Pane…", systemImage: "pencil") {
                beginRename(label: label)
            }),
            .separator
        ] + splitEntries + [
            .item(PopUpMenuItem(
                title: "Close Pane",
                systemImage: "xmark.square",
                shortcut: MenuCommand.closePane.shortcut(in: keyboard),
                isDestructive: true
            ) {
                onSurface { $0.onRequestCloseActivePane?() }
            })
        ]
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
    /// pane strip's tabs, the sidebar's rows, or another pane exactly as the ⌥⌘ drag does. It needs the
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
