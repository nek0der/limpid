// ContainerRow.swift
// Limpid — single row in the container slab. All five row shapes
// (Loose / Group / Project header / Worktree leaf / project-direct
// "general" leaf) render through the same view. Layout follows the
// reference screenshot:
//
//   [● palette-dot] [Label]               [count]  [chevron]
//
// Selection draws a rounded pill stroke + fill around the row.
// Section indents stay shallow (just slab padding); nested rows under
// an expanded Project / Group indent by an extra step so the
// hierarchy reads at a glance.

import SwiftUI

/// What a single row in container column represents. The view picks indent, icon,
/// chevron behavior, and trailing accessories from this.
enum ContainerRowKind: Equatable {
    case loose(count: Int)
    case group(TabGroup, count: Int, isExpanded: Bool)
    case projectHeader(Project, totalCount: Int, isExpanded: Bool)
    case worktree(projectID: UUID, Worktree, count: Int)
    /// Single tab inline-listed under an expanded Group. Lets users
    /// peek into a Group from container column without leaving the current container.
    case groupTab(Tab)

    /// `true` when the row should expose a hover-revealed delete (×)
    /// at its right edge. Daily / weekly destructive actions
    /// (closing a tab, hiding a worktree, dropping an empty group)
    /// belong here. Long-lived top-level rows — currently only
    /// project headers — opt out so the delete affordance doesn't
    /// invite accidental teardown; users still reach it from the
    /// row's context menu, which carries the proper confirm flow.
    var allowsHoverDelete: Bool {
        switch self {
        case .projectHeader: false
        default: true
        }
    }
}

extension ContainerRowKind {
    /// Context-menu label for the "…Settings…" entry. Reads "Group
    /// Settings…" on group rows and "Project Settings…" everywhere else
    /// it's exposed (project headers).
    var settingsMenuLabel: LocalizedStringResource {
        switch self {
        case .group: "Group Settings…"
        default: "Project Settings…"
        }
    }

    var settingsMenuIcon: String {
        switch self {
        case .group: "square.stack.3d.up"
        default: "folder.badge.gearshape"
        }
    }

    /// "Close" reads more accurately than "Delete" for Projects (the
    /// folder on disk lives on) and Groups (purely a Limpid grouping).
    /// Tabs ("groupTab") still use Close as well — it ends the
    /// session, not destructive in the on-disk sense.
    ///
    /// Returns `LocalizedStringResource` (not `String`) so the resolved
    /// text is taken from the String Catalog on render — passing a
    /// plain `String` to `Button(_:)` bypasses SwiftUI's localization
    /// path (catalog only kicks in for literal `LocalizedStringKey`).
    var closeLabel: LocalizedStringResource {
        switch self {
        case .projectHeader: "Close Project"
        case .group: "Close Group"
        case let .worktree(_, w, _):
            // For an orphan whose disk-side worktree is gone, the
            // verb is just "Remove Row" — there's nothing to hide
            // because the disk state is already "gone".
            w.isMissing ? "Remove Row" : "Remove from Sidebar"
        case .groupTab, .loose: "Close"
        }
    }

    /// SF Symbol paired with `closeLabel`. Worktree rows use the
    /// "hide" metaphor (the disk-side worktree stays put) so we pick
    /// an eye-with-slash; everything else genuinely closes/destroys
    /// the entity in Limpid, so the standard ✕ reads correctly.
    /// Single icon used by BOTH the context-menu destructive entry
    /// and the hover-revealed trailing button. Apple convention is
    /// simple symbols (no `.circle`) in context menus and inline
    /// actions, so we drop the suffixed forms entirely.
    var closeIcon: String {
        switch self {
        case let .worktree(_, w, _):
            w.isMissing ? "xmark" : "eye.slash"
        default:
            "xmark"
        }
    }

    var hoverDeleteHelp: LocalizedStringResource {
        switch self {
        case let .worktree(_, w, _):
            w.isMissing ? "Remove Row" : "Hide from Sidebar"
        default:
            "Delete"
        }
    }
}

/// Bundle of optional callbacks + flags a `ContainerRow` may carry.
/// Splitting them off the view's argument list keeps call sites
/// readable (the slab used to thread 11 named closures) and gives
/// new affordances a single struct to land on instead of growing
/// `ContainerRow.init`'s signature each time.
struct ContainerRowActions {
    /// Hover-revealed trailing button + context-menu close. Nil means
    /// the row can't be removed.
    var onDelete: (() -> Void)?
    /// Palette-index setter for the color picker popover. Only Group
    /// / Project header rows pass a real closure.
    var onChangePalette: ((Int) -> Void)?
    /// Reorder within the sibling list (single-slot move). Nil hides
    /// that context-menu entry.
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var canMoveUp: Bool = true
    var canMoveDown: Bool = true
    /// Project header only — "New Worktree…" context menu entry and
    /// hover-revealed "+" affordance.
    var onCreateWorktree: (() -> Void)?
    /// Project header only — "Show Hidden Worktrees" entry, surfaced
    /// only when at least one row is hidden.
    var onShowHiddenWorktrees: (() -> Void)?
    /// Project header only — "Project Settings…" context menu entry.
    var onOpenSettings: (() -> Void)?
    /// Project header only — "Sync Worktrees" entry.
    var onSyncWorktrees: (() -> Void)?
    /// Project header only — "Remove Missing Worktrees" entry, only
    /// when at least one row is currently flagged `isMissing`.
    var onPruneMissingWorktrees: (() -> Void)?
    /// Worktree row only — destructive "Delete Worktree…" that runs
    /// `git worktree remove`. Distinct from `onDelete` (which hides
    /// the row without touching disk).
    var onDeleteOnDisk: (() -> Void)?
    /// Worktree row only — "Reveal in Finder" entry.
    var onRevealInFinder: (() -> Void)?
    /// Tooltip on hover (typically the full path for worktree rows).
    var helpText: String?
}

struct ContainerRow: View {
    /// Drag descriptor consumed by `ContainerRow` to attach the
    /// `.limpidDraggable` modifier from *inside* the row's view body.
    ///
    /// Applying `.limpidDraggable` at the call site (outside
    /// `ContainerRow`) regressed on macOS 26: the row's internal
    /// `.contentShape(Rectangle())` + `.simultaneousGesture(TapGesture)`
    /// + `.contextMenu` claim the hit area first, so the outer
    /// `.draggable` long-press recognizer never wins arbitration and
    /// the drag session never starts. tab column `TabRow` does not regress
    /// because it applies `.limpidDraggable` at the *end* of its own
    /// body — we mirror that pattern here.
    struct DragDescriptor {
        let kind: LimpidDragState.Kind
        let prefix: String
        let id: String
        let dragState: LimpidDragState
    }

    let kind: ContainerRowKind
    let isActive: Bool
    /// `true` when a descendant of this row owns selection — e.g. a
    /// project header whose worktree is the active container. Draws a
    /// softer "in-the-path" pill (lighter fill, no stroke) so the
    /// descendant's selection remains the dominant visual cue.
    var isDescendantActive: Bool = false
    /// True if any tab in this container (or any container nested
    /// under it for project headers) has unread notifications.
    let hasUnread: Bool
    /// True while a bell is actively flashing inside this container.
    /// Drives the `symbolEffect(.bounce)` animation on the bell.
    var isRinging: Bool = false
    /// Aggregated Claude agent state across the container's panes.
    /// `nil` means no claude is running / all idle — the row stays
    /// quiet. The caller computes it from `WindowSession.aggregateAgentState`.
    var agentState: AgentState?
    /// True when the aggregate `.finished` is fully viewed — render the
    /// check gray ("seen, not yet replied") instead of green.
    var agentStateViewed: Bool = false
    /// Per-state pane counts used for the agent icon's hover tooltip.
    /// Empty dict when no claude is running.
    var agentBreakdown: [AgentState: Int] = [:]
    let onActivate: () -> Void
    /// Chevron click for Project / Group rows. Nil disables.
    let onToggleExpand: (() -> Void)?
    /// Rename submit. Nil disables inline rename for that kind.
    let onRename: ((String) -> Void)?
    /// Optional callbacks + flags — see `ContainerRowActions`.
    var actions: ContainerRowActions = .init()
    /// When non-nil, attaches `.limpidDraggable` to the row body from
    /// *inside* the view so the drag recognizer can win against the
    /// row's own tap / context-menu gestures. See `DragDescriptor`.
    var dragDescriptor: DragDescriptor?

    // MARK: - Action passthroughs

    //
    // Internal code reads these via the short name; storing them on a
    // bundle keeps `ContainerRow.init` callers from passing eleven
    // optional closures by name.

    private var onDelete: (() -> Void)? {
        actions.onDelete
    }

    private var onChangePalette: ((Int) -> Void)? {
        actions.onChangePalette
    }

    private var onMoveUp: (() -> Void)? {
        actions.onMoveUp
    }

    private var onMoveDown: (() -> Void)? {
        actions.onMoveDown
    }

    private var canMoveUp: Bool {
        actions.canMoveUp
    }

    private var canMoveDown: Bool {
        actions.canMoveDown
    }

    private var onCreateWorktree: (() -> Void)? {
        actions.onCreateWorktree
    }

    private var onShowHiddenWorktrees: (() -> Void)? {
        actions.onShowHiddenWorktrees
    }

    private var onOpenSettings: (() -> Void)? {
        actions.onOpenSettings
    }

    private var onSyncWorktrees: (() -> Void)? {
        actions.onSyncWorktrees
    }

    private var onPruneMissingWorktrees: (() -> Void)? {
        actions.onPruneMissingWorktrees
    }

    private var onDeleteOnDisk: (() -> Void)? {
        actions.onDeleteOnDisk
    }

    private var onRevealInFinder: (() -> Void)? {
        actions.onRevealInFinder
    }

    private var helpText: String? {
        actions.helpText
    }

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft = ""
    @State private var isColorPickerPresented = false
    @Environment(\.limpidAccent) private var limpidAccent

    var body: some View {
        // Two top-level branches instead of routing `.draggable` through
        // a `@ViewBuilder` helper. The helper version (`_ConditionalContent`
        // wrapping the modifier) appears to drop SwiftUI's drag-gesture
        // registration on macOS 26 — drags never started even with the
        // chain otherwise identical to TabRow. Splitting at body level
        // keeps each branch a concrete chain so `.draggable` lands on the
        // real view.
        if let descriptor = dragDescriptor {
            rowContent
                .opacity(rowOpacity(draggingID: descriptor.dragState.currentSourceID, myID: descriptor.id))
                .limpidDraggable(
                    kind: descriptor.kind,
                    prefix: descriptor.prefix,
                    id: descriptor.id,
                    dragState: descriptor.dragState
                )
        } else {
            rowContent
                .opacity(isMissingWorktree ? 0.5 : 1.0)
        }
    }

    /// Dim the row to ~0.4 while it's the active drag source so the
    /// user can tell *which* row is following the cursor. Live reorder
    /// moves the row into its hovered position immediately, so without
    /// this dim cue the dragged row looks indistinguishable from the
    /// rest of the list.
    private func rowOpacity(draggingID: String?, myID: String) -> Double {
        let baseline = isMissingWorktree ? 0.5 : 1.0
        return draggingID == myID ? min(baseline, 0.4) : baseline
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            leadingMarker
            if onRename != nil {
                // Renameable kinds use `InlineRenameField` (Text↔
                // SwiftUI-TextField swap — see that file for why the
                // swap pattern beats a persistent TextField on macOS
                // 26: the `NSWindow` shared field editor leaks scroll
                // state between rows when the same `NSTextField` backing
                // is reused).
                InlineRenameField(
                    text: $draft,
                    isEditing: $isEditing,
                    font: .system(size: 13, weight: .semibold, design: .rounded),
                    foregroundColor: labelColor,
                    onCommit: { value in commitRename(value) },
                    onCancel: { cancelRename() }
                )
                .layoutPriority(1)
                // `simultaneousGesture` (not `.onTapGesture`) so the
                // double-tap recognizer doesn't gate single-click
                // delivery to the inner TextField while editing — same
                // lesson as PR #50 for the row's activation tap. The
                // closure still no-ops when already editing.
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        if !isEditing { beginRename() }
                    }
                )
                .onChange(of: label) { _, newValue in
                    if !isEditing { draft = newValue }
                }
                .onAppear {
                    if !isEditing { draft = label }
                }
            } else {
                // `maxWidth: .infinity` so the label takes the row's
                // full free width even when the text itself is short —
                // otherwise the trailing accessories collapse left
                // toward the label and the count drifts away from the
                // right edge (visible on Quick Tabs / general rows).
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(labelColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            trailingAccessory
        }
        .padding(.leading, indent)
        .padding(.trailing, 18)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectablePillBackground(
            isActive: isActive,
            isHovering: isHovering,
            isDescendantActive: isDescendantActive
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // `.simultaneousGesture(TapGesture)` instead of `.onTapGesture`
        // because the latter waits for macOS's double-click resolution
        // window (~250 ms) before firing — the inner
        // `.onTapGesture(count: 2)` on the rename field puts the whole
        // row into "could still be a double-click" territory. The
        // `simultaneous` variant short-circuits that wait and feels
        // immediate. Drag is unaffected: the real cause of the earlier
        // drag regression was `.glassEffect` blocking hit-testing
        // (fixed separately), not the tap recognizer.
        .simultaneousGesture(
            TapGesture().onEnded {
                if isEditing { return }
                onActivate()
            }
        )
        .contextMenu {
            if onMoveUp != nil || onMoveDown != nil {
                if let onMoveUp {
                    Button(action: onMoveUp) {
                        Label("Move Up", systemImage: "arrow.up")
                    }
                    .disabled(!canMoveUp)
                    .tint(Color.primary)
                }
                if let onMoveDown {
                    Button(action: onMoveDown) {
                        Label("Move Down", systemImage: "arrow.down")
                    }
                    .disabled(!canMoveDown)
                    .tint(Color.primary)
                }
                Divider()
            }
            if onChangePalette != nil {
                Button {
                    isColorPickerPresented = true
                } label: {
                    Label("Change Color", systemImage: "paintpalette")
                }
                .tint(Color.primary)
            }
            if onRename != nil {
                Button {
                    beginRename()
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                .tint(Color.primary)
            }
            if let onCreateWorktree {
                Divider()
                Button(action: onCreateWorktree) {
                    Label("New Worktree…", systemImage: "arrow.triangle.branch")
                }
                .tint(Color.primary)
            }
            if let onShowHiddenWorktrees {
                Button(action: onShowHiddenWorktrees) {
                    Label("Show Hidden Worktrees", systemImage: "eye")
                }
                .tint(Color.primary)
            }
            if let onSyncWorktrees {
                Button(action: onSyncWorktrees) {
                    Label("Sync Worktrees", systemImage: "arrow.clockwise")
                }
                .tint(Color.primary)
            }
            if let onPruneMissingWorktrees {
                Button(action: onPruneMissingWorktrees) {
                    Label("Remove Missing Worktrees", systemImage: "exclamationmark.triangle")
                }
                .tint(Color.primary)
            }
            if let onOpenSettings {
                Divider()
                Button(action: onOpenSettings) {
                    Label {
                        Text(kind.settingsMenuLabel)
                    } icon: {
                        Image(systemName: kind.settingsMenuIcon)
                    }
                }
                .tint(Color.primary)
            }
            if let onRevealInFinder {
                Divider()
                Button(action: onRevealInFinder) {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .tint(Color.primary)
            }
            if let onDelete {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label {
                        Text(closeLabel)
                    } icon: {
                        Image(systemName: closeIcon)
                    }
                }
                .tint(Color.primary)
            }
            if let onDeleteOnDisk {
                Button(role: .destructive, action: onDeleteOnDisk) {
                    Label("Delete Worktree…", systemImage: "trash")
                }
                .tint(Color.primary)
            }
        }
        .modifier(OptionalHelp(text: helpText))
    }

    // MARK: - Leading marker (palette dot, branch icon, or unread)

    private var leadingMarker: some View {
        ZStack {
            switch kind {
            case .loose:
                Image(systemName: "tray")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            case let .group(g, _, _):
                paletteDotButton(paletteColor(g.paletteIndex), current: g.paletteIndex)
            case let .projectHeader(p, _, _):
                paletteDotButton(paletteColor(p.paletteIndex), current: p.paletteIndex)
            case .worktree:
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            case .groupTab:
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: LimpidLayout.containerColumnMarkerSlot, height: LimpidLayout.containerColumnMarkerSlot)
    }

    private func paletteColor(_ idx: Int?) -> Color {
        LimpidColor.paletteColor(idx)
    }

    /// 8px dot. When `onChangePalette` is set, the slot becomes
    /// tappable (high-priority so the row's `onActivate` tap doesn't
    /// swallow it) and anchors the color-picker popover. Hover ring
    /// hints that the dot is interactive.
    @ViewBuilder
    private func paletteDotButton(_ color: Color, current: Int?) -> some View {
        if onChangePalette != nil {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(4)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    TapGesture().onEnded {
                        isColorPickerPresented = true
                    }
                )
                .help("Change Color")
                .popover(isPresented: $isColorPickerPresented, arrowEdge: .bottom) {
                    ContainerColorPicker(current: current) { idx in
                        onChangePalette?(idx)
                        isColorPickerPresented = false
                    }
                    .limpidAccentPropagated(limpidAccent)
                }
        } else {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
    }

    // MARK: - Label

    private var label: String {
        switch kind {
        case .loose: String(localized: "Quick Tabs")
        case let .group(g, _, _): g.name
        case let .projectHeader(p, _, _): p.name
        case let .worktree(_, w, _): w.label
        case let .groupTab(t): t.displayTitle
        }
    }

    private var labelColor: Color {
        // Tahoe dark mode pushes `.secondary` to ~55% white which the
        // user flagged as too dim. Use full primary for active and
        // ~85% for everything else so labels stay legible without the
        // contrast leaking into the active highlight.
        if isActive { return .primary }
        switch kind {
        case .worktree, .groupTab:
            return Color.primary.opacity(0.78)
        default:
            return Color.primary.opacity(0.92)
        }
    }

    // MARK: - Trailing (count + chevron)

    /// True when this row represents a worktree that has been
    /// externally removed from disk. Drives the dim + warning badge.
    private var isMissingWorktree: Bool {
        if case let .worktree(_, w, _) = kind { return w.isMissing }
        return false
    }

    /// Trailing accessory — bell + count always in layout; hover
    /// action buttons (delete / new-worktree) join the HStack only
    /// while the row is hovered. That means the label reflows on
    /// hover enter/leave: ~32pt of label width shrinks to make room
    /// for the buttons. We chose this over an `.overlay` after the
    /// overlay landed icons on top of the label tail (truncated "…"
    /// would sit under the buttons), which read badly. The reflow
    /// is a tradeoff: the label is fuller at rest, and
    /// hover icons sit cleanly in their own slot during interaction.
    private var trailingAccessory: some View {
        HStack(spacing: 6) {
            if isMissingWorktree {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("Worktree not found on disk")
            }
            if isHovering, !isEditing, let onCreateWorktree {
                // Create-worktree (Y) stays inside the trailing group
                // — it sits next to the project header it belongs to,
                // not at the row edge, so it never collides with a
                // sibling row's delete affordance.
                Button(action: onCreateWorktree) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Worktree…")
            }
            if let state = agentState,
               let iconName = state.iconName,
               let iconColor = state.iconColor
            {
                let tooltip = agentTooltip(for: state)
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state == .finished && agentStateViewed
                        ? Color.secondary
                        : iconColor)
                    .frame(width: 16, height: 16)
                    .help(tooltip)
                    // Color is the only sighted differentiator (red /
                    // orange / blue / green). VoiceOver gets nothing
                    // from the SF Symbol name, so promote the
                    // tooltip text into the AX label as well — the
                    // CODING-GUIDELINES rule about color carrying
                    // meaning applies here twice over.
                    .accessibilityLabel(Text(tooltip))
            }
            NotificationBell(
                isUnread: hasUnread,
                isRinging: isRinging,
                reservesSlot: true
            )
            trailingControl
            // Delete (×) lives at the absolute right edge of the row
            // when hovered — matches the TabRow close affordance
            // and gives worktree / group rows a consistent "destructive
            // action on the far right" mental model. The slot is
            // unconditionally rendered (only the image is hidden when
            // not hovered) so the right edge of the row doesn't shift
            // on hover-in / hover-out.
            //
            // Project headers opt out via `kind.allowsHoverDelete`
            // because removing a project is a year-scale operation
            // that belongs in the context menu, not on a quick
            // hover slip.
            if let onDelete, kind.allowsHoverDelete {
                Button(action: onDelete) {
                    Image(systemName: hoverDeleteIcon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .opacity(isHovering && !isEditing ? 1 : 0)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(isHovering && !isEditing)
                .help(String(localized: hoverDeleteHelp))
                .accessibilityLabel(Text(hoverDeleteHelp))
            }
        }
    }

    /// Build the "1 error · 2 needs input · 1 running · 3 idle" tooltip
    /// from `agentBreakdown`. 0-count states are omitted so the string
    /// stays scannable. Each per-state label and the bullet separator
    /// route through the catalog so a ja user reads "1 エラー · 2 入力待ち"
    /// instead of the raw Swift case identifiers the earlier version
    /// leaked.
    private func agentTooltip(for dominant: AgentState) -> String {
        let order: [AgentState] = [.error, .needsInput, .finished, .running, .compacting, .idle, .unknown]
        var parts: [String] = []
        for state in order {
            let count = agentBreakdown[state] ?? 0
            guard count > 0 else { continue }
            parts.append("\(count) \(state.localizedLabel)")
        }
        return parts.isEmpty
            ? dominant.localizedLabel
            : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch kind {
        case .loose, .group, .worktree:
            // Tab count is intentionally not surfaced on container column any more
            // — the agent-state icon owns the trailing "at-a-glance"
            // role, and the tab count is one click away in tab column. Keeps
            // the trailing grid pure (state · bell · chevron, all 16×16).
            EmptyView()
        case let .projectHeader(_, _, expanded):
            // Project headers always reserve a 16×16 slot in the
            // chevron position so worktree rows below align with the
            // header even on non-git projects. Without `onToggleExpand`
            // the slot stays empty (no glyph, no hit target — a
            // disclosure that doesn't disclose would be a dead
            // control); with it, the same slot carries the chevron
            // button.
            if let onToggleExpand {
                Button(action: { onToggleExpand() }, label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.70))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                })
                .buttonStyle(.plain)
                .help(expanded ? "Collapse" : "Expand")
                .accessibilityLabel(Text(expanded ? "Collapse" : "Expand"))
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        case .groupTab:
            EmptyView()
        }
    }

    // MARK: - Geometry

    private var indent: CGFloat {
        // All rows share the same leading inset; hierarchy reads from
        // the slab tree structure + marker icon change, not from
        // horizontal indent.
        LimpidLayout.containerColumnIndentTop
    }

    private var rowHeight: CGFloat {
        switch kind {
        case .loose, .group, .projectHeader:
            LimpidLayout.containerColumnRowHeightTop
        case .worktree, .groupTab:
            LimpidLayout.containerColumnRowHeightNested
        }
    }

    // MARK: - Rename

    private func beginRename() {
        draft = label
        isEditing = true
    }

    private func commitRename(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onRename?(trimmed)
        } else {
            // Empty / all-whitespace submit means "keep the prior
            // name". The inner `TextField` already pushed `""` into
            // `draft`, so without this resync the row would render
            // blank until something else made `label` change. The
            // cancel path already does this on its own.
            draft = label
        }
        isEditing = false
    }

    private func cancelRename() {
        draft = label
        isEditing = false
    }

    /// `closeLabel` / `closeIcon` / `hoverDeleteIcon` / `hoverDeleteHelp`
    /// are kind-derived and live on `ContainerRowKind` (below) so the
    /// view's struct body stays within the lint length budget.
    private var closeLabel: LocalizedStringResource {
        kind.closeLabel
    }

    private var closeIcon: String {
        kind.closeIcon
    }

    private var hoverDeleteIcon: String {
        kind.closeIcon
    }

    private var hoverDeleteHelp: LocalizedStringResource {
        kind.hoverDeleteHelp
    }
}

extension View {
    /// Conditionally attaches `.limpidDraggable` from inside the
    /// container row's body. Used by `ContainerRow` to win gesture
    /// arbitration against its own tap / context-menu recognizers —
    /// see `ContainerRow.DragDescriptor` for the full rationale.
    @ViewBuilder
    @MainActor
    func applyLimpidDraggable(_ descriptor: ContainerRow.DragDescriptor?) -> some View {
        if let descriptor {
            limpidDraggable(
                kind: descriptor.kind,
                prefix: descriptor.prefix,
                id: descriptor.id,
                dragState: descriptor.dragState
            )
        } else {
            self
        }
    }
}

private struct OptionalHelp: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}
