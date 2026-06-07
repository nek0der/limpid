// TabRow.swift
// Limpid — single row in the tab list. Flat list (no indent for
// hierarchy — that lives in container column). Shows an unread dot, the title, and
// hover/active close button. Inline rename on double-click.

import SwiftUI

struct TabRow: View {
    @Environment(WindowSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(LimpidDragState.self) private var dragState
    let tab: Tab
    let onActivate: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onUnzoom: () -> Void
    /// Fires when the row enters / leaves inline-rename. The horizontal
    /// tab strip uses this to widen a narrow tab while it's being
    /// edited; the vertical list leaves it unset (no width change).
    var onEditingChanged: ((Bool) -> Void)?
    /// Horizontal padding the pill background inherits from the row's
    /// content edge. The vertical list keeps the default so pills sit
    /// inset from the column edges; the horizontal strip collapses it
    /// so adjacent pills don't carry a wide phantom gap on each side.
    var pillHorizontalPadding: CGFloat = 10

    @State private var isEditing = false
    @State private var isHovering = false
    @State private var draft = ""

    private var isActive: Bool {
        session.activeTabID == tab.id
    }

    private var hasUnread: Bool {
        session.hasUnread(in: tab)
    }

    private var isRinging: Bool {
        session.isRinging(in: tab)
    }

    private var isZoomed: Bool {
        tab.zoomedLeafID != nil
    }

    /// Aggregate agent state across every split leaf in the tab and
    /// pick the most-urgent state for the tab column icon. Pulls from both
    /// `claudeAgentBadges` and `codexAgentBadges` via the shared
    /// session helper so a Codex pane lights up the badge too.
    private var aggregateAgentState: AgentState? {
        attention.aggregateAgentState(in: tab)
    }

    /// Whether the tab's finished turn(s) are all viewed — drives the
    /// gray (vs green) check on the activity badge.
    private var aggregateViewed: Bool {
        attention.isFinishedAggregateViewed(in: tab)
    }

    /// Leading identity icon: does an AI agent (Claude or Codex) have
    /// a live session in any of this tab's panes — whether actively
    /// working or sitting idle? Distinct from `aggregateAgentState`,
    /// which drives the trailing *activity* badge: a tab where the
    /// agent sits idle waiting for the next prompt is still an agent
    /// tab (`.idle` counts) even though it shows no activity badge.
    /// We key off badge *presence* with a non-`.unknown` state so the
    /// icon flips back to a plain terminal once the session ends or
    /// the badge is dropped.
    private var isAgentTab: Bool {
        tab.splitTree.allLeafIDs().contains { leaf in
            if let s = tab.claudeAgentBadges[leaf]?.state, s != .unknown { return true }
            if let s = tab.codexAgentBadges[leaf]?.state, s != .unknown { return true }
            return false
        }
    }

    /// Build the hover tooltip for the agent-state icon. Includes
    /// the dominant pane's detail and elapsed seconds when a single
    /// pane is involved; falls back to a count summary for multi-
    /// pane mixes. Claude and Codex badges share `AgentState` so we
    /// project both kinds onto a single tuple list for the reducer.
    private func agentTooltip(for state: AgentState) -> String {
        struct UnifiedBadge {
            let state: AgentState
            let detail: String?
            let runStartedAt: Date?
            let updatedAt: Date
        }
        let leaves = tab.splitTree.allLeafIDs()
        var badges: [UnifiedBadge] = []
        for leaf in leaves {
            if let b = tab.claudeAgentBadges[leaf] {
                badges.append(UnifiedBadge(
                    state: b.state,
                    detail: b.detail,
                    runStartedAt: b.runStartedAt,
                    updatedAt: b.updatedAt
                ))
            }
            if let b = tab.codexAgentBadges[leaf] {
                badges.append(UnifiedBadge(
                    state: b.state,
                    detail: b.detail,
                    runStartedAt: b.runStartedAt,
                    updatedAt: b.updatedAt
                ))
            }
        }
        let matching = badges.filter { $0.state == state }
        let dominant = matching.max { lhs, rhs in
            lhs.updatedAt < rhs.updatedAt
        }
        let stateLabel = switch state {
        case .running, .compacting, .needsInput, .error, .finished: state.localizedLabel
        case .idle, .unknown: ""
        }
        var pieces: [String] = [stateLabel]
        if matching.count > 1 {
            pieces.append(String(
                localized: "(\(matching.count) of \(badges.count) panes)",
                comment: "Agent state tooltip — match count out of total panes"
            ))
        }
        if let detail = dominant?.detail, !detail.isEmpty {
            pieces.append("· \(detail)")
        }
        if state == .running || state == .compacting,
           let started = dominant?.runStartedAt
        {
            let elapsed = Int(Date().timeIntervalSince(started))
            if elapsed >= 0 {
                pieces.append(String(
                    localized: "· \(elapsed)s",
                    comment: "Agent state tooltip — elapsed seconds suffix"
                ))
            }
        }
        return pieces.joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 8) {
            // Leading identity glyph: a bolt mark when an agent has
            // a live session in the tab (currently Claude, via the shim
            // hooks), otherwise a plain terminal mark. Always present so
            // the row reads as "AI vs plain terminal" at a glance. We
            // distinguish by glyph only — both share the same monochrome
            // tint so the AI rows don't shout with an accent color.
            Image(systemName: isAgentTab ? "bolt" : "terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            InlineRenameField(
                text: $draft,
                isEditing: $isEditing,
                font: .system(size: 13, weight: .medium, design: .rounded),
                foregroundColor: isActive ? .primary : .secondary,
                onCommit: { value in commitRename(value) },
                onCancel: { cancelRename() }
            )
            .layoutPriority(1)
            // `simultaneousGesture` (not `.onTapGesture`) so this double-
            // tap recognizer doesn't gate single-click delivery to the
            // inner TextField while editing — same lesson as PR #50 for
            // the row's activation tap. The closure still no-ops when
            // already editing.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    if !isEditing { beginRename() }
                }
            )
            .onChange(of: tab.displayTitle) { _, new in
                if !isEditing { draft = new }
            }
            .onAppear {
                if !isEditing { draft = tab.displayTitle }
            }
            // ⌘⇧R posts this; only the matching row reacts so cross-
            // container renames don't fire the wrong row.
            .onReceive(NotificationCenter.default.publisher(for: .limpidRenameActiveTab)) { note in
                if (note.object as? UUID) == tab.id, !isEditing { beginRename() }
            }
            Spacer(minLength: 4)
            if let state = aggregateAgentState,
               let iconName = state.iconName,
               let iconColor = state.iconColor
            {
                // Agent rows show the lifecycle badge as their single
                // status mark. The bell is suppressed here so we don't
                // stack two indicators for the same event — the agent's
                // OS notification + history entry still fire; the bell
                // is reserved for non-agent unread (terminal OSC 9/777,
                // child-exit, etc.) on rows that have no agent badge.
                let tooltip = agentTooltip(for: state)
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state == .finished && aggregateViewed
                        ? Color.secondary
                        : iconColor)
                    .frame(width: 16, height: 16)
                    .help(tooltip)
                    // Match `ContainerRow`'s sister fix: SF Symbol names
                    // alone don't carry meaning, especially when the
                    // color is the only sighted differentiator.
                    .accessibilityLabel(Text(tooltip))
            } else {
                NotificationBell(
                    isUnread: hasUnread,
                    isRinging: isRinging,
                    reservesSlot: true
                )
            }
            if isZoomed {
                // Always-visible state indicator with a tap target so the
                // user can leave zoom mode without remembering ⌘⇧Return.
                // Sits between the bell (passive status) and the close
                // button (action) since it's an actionable affordance.
                Button(action: onUnzoom) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Unzoom Pane")
                .accessibilityLabel(Text("Unzoom Pane"))
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab")
            .accessibilityLabel(Text("Close Tab"))
            .opacity(isActive || isHovering ? 1 : 0)
            .allowsHitTesting(isActive || isHovering)
        }
        // Hold the *visible* pill inset (icon-to-pill-edge) constant
        // across vertical / horizontal layouts. Because the pill
        // background is itself inset by `pillHorizontalPadding`, the
        // content padding has to grow in lockstep — otherwise the
        // horizontal strip (which uses pillHorizontalPadding = 0) reads
        // as more spacious on the left than the vertical list.
        .padding(.leading, 18 + pillHorizontalPadding)
        .padding(.trailing, 4 + pillHorizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectablePillBackground(
            isActive: isActive,
            isHovering: isHovering,
            horizontalPadding: pillHorizontalPadding
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: isEditing) { _, editing in
            onEditingChanged?(editing)
        }
        // `.simultaneousGesture(TapGesture)` instead of `.onTapGesture`
        // because the latter waits for macOS's double-click resolution
        // window (~250ms) before firing — the inner
        // `.onTapGesture(count: 2)` on the rename field puts the whole
        // row into "could still be a double-click" territory. The
        // `simultaneous` variant short-circuits that wait and feels
        // immediate. Mirrors the pattern `ContainerRow` already uses
        // on container column; without it, switching tabs in tab column felt one tempo late
        // and would occasionally land on a momentarily-empty terminal column
        // because the delayed handler dispatched while SwiftUI was
        // still settling the previous frame.
        .simultaneousGesture(
            TapGesture().onEnded {
                if isEditing { return }
                onActivate()
            }
        )
        .contextMenu {
            Button {
                beginRename()
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            .tint(Color.primary)
            Divider()
            Button(role: .destructive, action: onClose) {
                Label("Close", systemImage: "xmark")
            }
            .tint(Color.primary)
        }
        // `limpidDraggable` wraps SwiftUI's `.draggable` — macOS 26
        // regressed the legacy `.onDrag` + `NSItemProvider` path so
        // drag sessions silently failed to start.
        .limpidDraggable(
            kind: .tab,
            prefix: "tab:",
            id: tab.id.uuidString,
            dragState: dragState
        )
    }

    private func beginRename() {
        draft = tab.displayTitle
        isEditing = true
    }

    private func commitRename(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty submit on a tab without a prior `titleOverride`
            // is a no-op assignment, so the value-guarded
            // `WindowSession.update` skips the write and
            // `.onChange(of: tab.displayTitle)` never fires to
            // resync `draft` — the pill would render blank. Bring
            // `draft` back in line with the live title ourselves.
            draft = tab.displayTitle
        } else {
            onRename(trimmed)
        }
        isEditing = false
    }

    private func cancelRename() {
        draft = tab.displayTitle
        isEditing = false
    }
}

// MARK: - TabsListView

/// The tab column body — flat list of TabRow for the active container, with
/// an empty-state when zero tabs exist. tab column used to be a mode picker
/// (Tabs / Log / Diff / Stash); after the mode switcher came out only
/// the tabs list survived, so this view is now the entire tab column body.
struct TabsListView: View {
    @Environment(WindowSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(LimpidDragState.self) private var dragState
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.claudeSessionTracker) private var claudeSessionTracker
    @Environment(\.cwdEventTracker) private var cwdEventTracker
    @Environment(\.codexSessionTracker) private var codexSessionTracker
    @Namespace private var paneMergeHighlight
    let container: ContainerID

    var body: some View {
        let tabs = session.tabs(in: container)
        // Resolve the source tab of the in-flight pane drag ONCE per
        // body re-render and hand the value down to each row. Computing
        // it inside `paneMergeDropTarget` would re-run
        // `session.tab(containing:)` for every visible row × every
        // drag-frame.
        let paneDragSourceTabID = Self.paneDragSourceTabID(
            dragState: dragState,
            session: session
        )
        if tabs.isEmpty {
            // Empty-state moved to terminal column so it stays centered in the main
            // area across both tab layouts (see `TerminalColumnEmptyState`). The
            // shape still accepts a pane drop so a user can detach into
            // an otherwise empty container.
            Color.clear
                .contentShape(Rectangle())
                .paneDetachDropTarget(
                    container: container,
                    session: session,
                    dragState: dragState
                )
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: LimpidLayout.reorderRowSpacing) {
                    ForEach(tabs) { tab in
                        TabRow(
                            tab: tab,
                            onActivate: {
                                // Flash + unread clear is handled in
                                // AppState via activeTabID observation —
                                // a single hook covers every navigation
                                // path (TabRow, container header, ⌘1-9,
                                // ⌘[/], restore) instead of duplicating
                                // it at each call site.
                                session.setActiveTab(tab.id)
                            },
                            onClose: {
                                TabActions.closeTab(
                                    session,
                                    registry: registry,
                                    tabID: tab.id,
                                    source: .mouse,
                                    attention: attention,
                                    claudeSessionTracker: claudeSessionTracker,
                                    codexSessionTracker: codexSessionTracker,
                                    cwdEventTracker: cwdEventTracker
                                )
                            },
                            onRename: { newName in
                                renameTab(tab.id, to: newName)
                            },
                            onUnzoom: {
                                // Activate the tab so the user can see the
                                // restored split layout, then clear zoom.
                                session.setActiveTab(tab.id)
                                session.update(tab.id) { t in
                                    t.zoomedLeafID = nil
                                }
                            }
                        )
                        .tabReorderTarget(beforeTabID: tab.id, container: container, session: session)
                        .paneMergeDropTarget(
                            targetTabID: tab.id,
                            session: session,
                            dragState: dragState,
                            highlightNamespace: paneMergeHighlight,
                            sourceTabID: paneDragSourceTabID
                        )
                    }
                }
                .padding(.vertical, 8)
                // Sliding-highlight animation: matchedGeometryEffect in
                // `paneMergeDropTarget` needs an explicit value-keyed
                // animation to interpolate the rectangle between rows
                // as the cursor crosses neighbours.
                .animation(LimpidMotion.paneMergeHighlight, value: dragState.hoverTargetID)
            }
            // tab column body catches drops that land between or below the rows.
            // Per-row merge targets shadow this when the cursor is over a
            // row — SwiftUI's drop dispatch picks the innermost match.
            .contentShape(Rectangle())
            .paneDetachDropTarget(
                container: container,
                session: session,
                dragState: dragState
            )
        }
    }

    private func renameTab(_ tabID: UUID, to newName: String) {
        session.update(tabID) { t in
            t.titleOverride = newName.isEmpty ? nil : newName
        }
    }

    /// Resolve the tab id of the pane currently being dragged. Lives
    /// here (as a private static helper) instead of `PaneTabColumnDropTargets`
    /// so the "computed once per body render, NOT per row" intent stays
    /// next to the only call site — pushing it into each
    /// `paneMergeDropTarget` would re-run `tab(containing:)` for every
    /// visible row × every drag-frame.
    private static func paneDragSourceTabID(
        dragState: LimpidDragState,
        session: WindowSession
    ) -> UUID? {
        guard dragState.current == .pane,
              let raw = dragState.currentSourceID,
              let paneID = UUID(uuidString: raw)
        else { return nil }
        return session.tab(containing: paneID)?.id
    }
}

// MARK: - In-list reorder helper (uses the shared insertion-line modifier)

extension View {
    /// Treat this tab row as a reorder target. The `isNoOp` closure
    /// hides the indicator for "drop where you already are" cases —
    /// dropping ON yourself, just before the next tab (= current
    /// position), or just after the previous tab (= current position).
    /// `axis` matches the layout: `.vertical` for the tab column list,
    /// `.horizontal` for the horizontal tab strip.
    func tabReorderTarget(
        beforeTabID: UUID,
        container: ContainerID,
        session: WindowSession,
        axis: Axis = .vertical
    ) -> some View {
        reorderableDropTarget(
            targetID: "tab-\(beforeTabID)",
            acceptedPrefixes: ["tab:"],
            axis: axis,
            isNoOp: { sourceID, position in
                guard sourceID != beforeTabID else { return true }
                // Cross-container drops always change something.
                guard let src = session.tab(sourceID),
                      src.container == container
                else { return false }
                let tabs = session.tabs(in: container)
                guard let targetIdx = tabs.firstIndex(where: { $0.id == beforeTabID }),
                      let srcIdx = tabs.firstIndex(where: { $0.id == sourceID })
                else { return false }
                switch position {
                case .before:
                    // Drop "before target" = no-op when source is the
                    // immediate predecessor (or the target itself).
                    return srcIdx == targetIdx - 1
                case .after:
                    // Drop "after target" = no-op when source is the
                    // immediate successor.
                    return srcIdx == targetIdx + 1
                }
            },
            onDrop: { _, sourceID, position in
                if let src = session.tab(sourceID),
                   src.container != container
                {
                    session.moveTab(sourceID, to: container)
                }
                switch position {
                case .before:
                    session.reorderTab(sourceID, before: beforeTabID)
                case .after:
                    session.reorderTab(sourceID, after: beforeTabID)
                }
            }
        )
    }
}
