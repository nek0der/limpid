// ContainerRow.swift
// Limpid — single row in the container slab. Every row shape (Quick
// Tabs / Group / Project header / Worktree leaf) renders through this
// view, in one of two layouts:
//
//   top-level   [marker] [Label]              [status…]
//   nested               [Label]              [status…]
//
// Every row starts at the same inset; a nested one simply draws
// nothing into the marker slot, which puts its label on exactly the
// left edge its parent's sits on. What tells the two apart is the
// absent marker, the lighter label, and the tinted rule
// `ProjectSectionView` draws down the marker column to span a
// project's children.
//
// A marker is only worth a slot when it says something that varies
// per row. The palette dot does — it is the project's identity, and
// the head of that tinted rule. A fixed glyph repeated on every
// worktree would not, so nested rows have none; the three signals
// above already say which kind of row this is.
//
// The trailing group is the row's status column. The bell anchors its
// right edge by holding a slot even when silent; everything else takes
// a slot only when it has something to report. Before that rule the
// group's right edge was set by whatever each kind happened to
// reserve — a disclosure chevron on Project rows, a hover delete on
// Group and worktree rows, and nothing at all on Quick Tabs, which
// therefore ended a slot short of every other row in the list. The
// disclosure has since moved to the dot, where macOS puts it
// (`NSOutlineView`, `DisclosureGroup`), and the delete appears on
// hover rather than holding a slot.
//
// Selection draws a rounded pill stroke + fill around the row.

import SwiftUI

/// What a single row in container column represents. The view picks
/// the marker, the disclosure behavior, and the trailing accessories
/// from this; the leading inset is the same for every kind.
enum ContainerRowKind: Equatable {
    case loose
    case group(TabGroup, isExpanded: Bool)
    case projectHeader(Project, isExpanded: Bool)
    case worktree(projectID: UUID, Worktree)

    /// `true` for rows that hang under a parent row. They draw nothing
    /// into the marker slot, which is what lands their label on the
    /// same left edge as their parent's.
    var isNested: Bool {
        switch self {
        case .worktree: true
        case .loose, .group, .projectHeader: false
        }
    }

    /// `true` when the row shows a delete at its right edge on hover.
    ///
    /// Groups only. They are made and dropped freely — an empty one
    /// closes without even a confirm — so the round trip through a
    /// context menu is friction on the app's most disposable row.
    /// Closing a project is a year-scale action and stays behind the
    /// menu, which routes it through a confirmation. A worktree needs
    /// no confirmation — one still on disk is merely hidden, and one
    /// already gone leaves nothing to lose — but it is long-lived
    /// enough that a hover slip should not take it off the sidebar.
    var allowsHoverDelete: Bool {
        switch self {
        case .group: true
        case .loose, .projectHeader, .worktree: false
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
    ///
    /// Returns `LocalizedStringResource` (not `String`) so the resolved
    /// text is taken from the String Catalog on render — passing a
    /// plain `String` to `Button(_:)` bypasses SwiftUI's localization
    /// path (catalog only kicks in for literal `LocalizedStringKey`).
    var closeLabel: LocalizedStringResource {
        switch self {
        case .projectHeader: "Close Project"
        case .group: "Close Group"
        case let .worktree(_, w):
            // For an orphan whose disk-side worktree is gone, the
            // verb is just "Remove Row" — there's nothing to hide
            // because the disk state is already "gone".
            w.isMissing ? "Remove Row" : "Remove from Sidebar"
        case .loose: "Close"
        }
    }

    /// SF Symbol paired with `closeLabel`. Both entries that use it —
    /// the context menu on every kind, the hover delete on Groups —
    /// take it from here so the two never disagree.
    ///
    /// A worktree still on disk is only hidden, so it gets the
    /// eye-with-slash; one already gone, like everything else here,
    /// genuinely stops existing in Limpid and takes the ✕. Apple
    /// convention is simple symbols (no `.circle`) in context menus,
    /// so we drop the suffixed forms.
    var closeIcon: String {
        switch self {
        case let .worktree(_, w):
            w.isMissing ? "xmark" : "eye.slash"
        default:
            "xmark"
        }
    }
}

/// Bundle of optional callbacks + flags a `ContainerRow` may carry.
/// Splitting them off the view's argument list keeps call sites
/// readable (the slab used to thread 11 named closures) and gives
/// new affordances a single struct to land on instead of growing
/// `ContainerRow.init`'s signature each time.
struct ContainerRowActions {
    /// Close the row — the context-menu entry, and on kinds that
    /// allow it the hover delete too. Nil means the row can't be
    /// removed.
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
    /// the hover-revealed branch affordance beside it.
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
    /// Per-state pane counts used for the agent icon's hover tooltip.
    /// Empty dict when no claude is running.
    var agentBreakdown: [AgentState: Int] = [:]
    let onActivate: () -> Void
    /// Toggle whether this row's children are shown. Reaches the user
    /// as the palette dot, which swaps to a chevron on hover. Nil
    /// disables.
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

    // Internal code reads these via the short name; storing them on a
    // bundle keeps `ContainerRow.init` callers from naming every
    // optional closure at each call site.

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
    /// Hover over the marker slot alone, not the row. Drives the
    /// dot → chevron swap, which must not fire from anywhere else on
    /// the row or the dot would flicker as the pointer crossed it.
    @State private var isMarkerHovering = false
    @Environment(\.limpidAccent) private var limpidAccent

    // Pull-request dependencies, all propagated by `LimpidApp` at
    // scene root. Read here rather than threaded through every call
    // site so `ContainerRow`'s init signature stays put. Everything
    // the feature draws goes through `prHoverCardTarget` below, which
    // is where the Settings switch is checked.
    @Environment(PRStatusStore.self) private var prStatusStore
    @Environment(\.prStatusSyncer) private var prStatusSyncer
    @Environment(SettingsStore.self) private var settingsStore

    // MARK: - Body

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
        HStack(spacing: LimpidLayout.containerColumnRowContentSpacing) {
            // Unconditional, even though a nested row draws nothing in
            // it. Dropping the slot from some rows makes the HStack's
            // shape differ per kind, and SwiftUI then animates the
            // markers of the surviving rows independently of their
            // labels when a sibling is removed — the dots slide into
            // place after the text has already settled. Reserving an
            // empty slot keeps every row the same shape and lines the
            // labels up at the same x, which is what the slot was for
            // to begin with.
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
                        if !isEditing {
                            beginRename()
                        }
                    }
                )
                .onChange(of: label) { _, newValue in
                    if !isEditing {
                        draft = newValue
                    }
                }
                .onAppear {
                    if !isEditing {
                        draft = label
                    }
                }
            } else {
                // `maxWidth: .infinity` so the label takes the row's
                // full free width even when the text itself is short —
                // otherwise the trailing accessories collapse left
                // toward the label instead of staying pinned to the
                // row's right edge.
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(labelColor)
                    // The renameable branch above carries this offset
                    // to line its static label up with the field
                    // editor. A row that can't be renamed has no field
                    // editor to match, but it does sit in the same
                    // list — without the same offset a worktree label
                    // lands 5pt left of its project's.
                    .padding(.leading, InlineRenameField.fieldEditorLeadingPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            trailingAccessory
        }
        .padding(.leading, LimpidLayout.containerColumnIndentTop)
        .padding(.trailing, LimpidLayout.containerColumnRowTrailingPadding)
        .frame(height: LimpidLayout.containerColumnRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Resolve the row's children against one geometry instead of
        // each their own, so a row that moves in the list carries its
        // marker, label and accessories as a single piece rather than
        // interpolating them independently.
        .geometryGroup()
        .selectablePillBackground(
            isActive: isActive,
            isHovering: isHovering,
            isDescendantActive: isDescendantActive,
            // A nested row starts its pill clear of the project rule
            // running down the marker column — see the constant.
            leadingPadding: kind.isNested ? LimpidLayout.containerColumnNestedPillLeading : nil
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
                if isEditing {
                    return
                }
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
            // Only offered on rows that have a request on file. On a
            // row with none, a refresh has nothing to refresh and the
            // entry would read as dead. It is deliberately not gated
            // on `showsPRMark`: under "only rows needing attention" a
            // healthy request draws nothing at rest, and that is
            // exactly the row where the user might want to re-ask.
            if let target = prHoverCardTarget, let prStatusSyncer {
                Divider()
                Button {
                    prStatusSyncer.refreshNow(container: target.container)
                } label: {
                    Label("Refresh PR Status", systemImage: "arrow.clockwise")
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
        // Suppress the path tooltip on rows that show a pull-request
        // card. Both are hover surfaces for the same row, and the
        // system tooltip appears later and draws on top — it would
        // cover the card the user is reading. The path stays reachable
        // from the row's context menu.
        .modifier(OptionalHelp(text: prHoverCardTarget == nil ? helpText : nil))
        // Attaches to the whole row so the hover target is the row,
        // not the mark. Resolves to nil — and the modifier to a no-op
        // — on every row that has no linked pull request.
        .prHoverCard(prHoverCardTarget)
    }

    // MARK: - Leading marker (palette dot / Quick Tabs glyph)

    /// Reached for every row. A nested row draws nothing into the
    /// slot but still reserves it, which is what puts its label on the
    /// same left edge as its parent's — see `rowContent` for why the
    /// slot cannot be made conditional.
    private var leadingMarker: some View {
        ZStack {
            switch kind {
            case .loose:
                // Quick Tabs sits above the sections, alone, with no
                // parent to align to. The glyph is what tells it apart
                // from a project.
                Image(systemName: ContainerSymbol.quickTabs)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            case let .group(g, _):
                paletteDot(paletteColor(g.paletteIndex))
            case let .projectHeader(p, _):
                paletteDot(paletteColor(p.paletteIndex))
            case .worktree:
                EmptyView()
            }
        }
        .frame(width: LimpidLayout.containerColumnMarkerSlot, height: LimpidLayout.containerColumnMarkerSlot)
    }

    /// `true` when this row's children are showing.
    private var isRowExpanded: Bool {
        switch kind {
        case let .group(_, expanded): expanded
        case let .projectHeader(_, expanded): expanded
        case .loose, .worktree: false
        }
    }

    private func paletteColor(_ idx: Int?) -> Color {
        LimpidColor.paletteColor(idx)
    }

    /// The project's color, and the row's disclosure control.
    ///
    /// macOS puts a disclosure on the leading edge (`NSOutlineView`,
    /// `DisclosureGroup`), where the dot already sits. Hovering swaps
    /// it for a chevron so the control announces itself before the
    /// click; the dot holds the slot otherwise, being also the head of
    /// the tinted rule spanning this project's children.
    ///
    /// One tap target can only mean one thing, so recoloring moved to
    /// the context menu — expanding is daily, recoloring rare. The
    /// picker's popover still anchors here, attached independently of
    /// `onToggleExpand` so a group row can be recolored without being
    /// expandable. `highPriorityGesture` so the tap beats the row's
    /// own activation rather than racing it.
    @ViewBuilder
    private func paletteDot(_ color: Color) -> some View {
        let dot = Circle().fill(color).frame(width: 10, height: 10)
        Group {
            if let onToggleExpand {
                ZStack {
                    dot.opacity(isMarkerHovering ? 0 : 1)
                    if isMarkerHovering {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .rotationEffect(.degrees(isRowExpanded ? 90 : 0))
                    }
                }
                .padding(4)
                .contentShape(Rectangle())
                .onHover { isMarkerHovering = $0 }
                // No `withAnimation` here: the action site owns the
                // transaction, the way `onMoveUp` and `onDelete` do.
                // Wrapping it again wrapped the same animation twice
                // and left callers no way to fold without one.
                .highPriorityGesture(TapGesture().onEnded { onToggleExpand() })
                .help(isRowExpanded ? "Collapse" : "Expand")
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(isRowExpanded ? "Collapse" : "Expand"))
            } else {
                dot
            }
        }
        .popover(isPresented: $isColorPickerPresented, arrowEdge: .bottom) {
            ContainerColorPicker(current: currentPaletteIndex) { idx in
                onChangePalette?(idx)
                isColorPickerPresented = false
            }
            .limpidAccentPropagated(limpidAccent)
        }
    }

    /// Palette slot this row currently sits on, so the picker opens
    /// with the right swatch selected.
    private var currentPaletteIndex: Int? {
        switch kind {
        case let .group(g, _): g.paletteIndex
        case let .projectHeader(p, _): p.paletteIndex
        case .loose, .worktree: nil
        }
    }

    // MARK: - Label

    private var label: String {
        switch kind {
        case .loose: String(localized: "Quick Tabs")
        case let .group(g, _): g.name
        case let .projectHeader(p, _): p.name
        case let .worktree(_, w): w.label
        }
    }

    private var labelColor: Color {
        // Tahoe dark mode pushes `.secondary` to ~55% white which the
        // user flagged as too dim. Use full primary for active and
        // ~85% for everything else so labels stay legible without the
        // contrast leaking into the active highlight.
        if isActive {
            return .primary
        }
        switch kind {
        case .worktree:
            return Color.primary.opacity(0.78)
        default:
            return Color.primary.opacity(0.92)
        }
    }

    // MARK: - Trailing (status column)

    /// True when this row represents a worktree that has been
    /// externally removed from disk. Drives the dim + warning badge.
    private var isMissingWorktree: Bool {
        if case let .worktree(_, w) = kind {
            return w.isMissing
        }
        return false
    }

    /// The container this row stands for, paired with its pull
    /// request — or nil when there is nothing to show, which includes
    /// the feature being switched off. Every part of the row that
    /// reads request state comes through here, so that one check is
    /// the whole master switch.
    ///
    /// A Project row resolves to its own main checkout: that is the
    /// container tapping the header activates, and `GitSyncCoordinator`
    /// keeps it out of `project.worktrees` precisely because this row
    /// already represents it. Groups and Quick Tabs
    /// have no branch of their own and resolve to nil.
    private var prHoverCardTarget: (container: ContainerID, info: PRInfo)? {
        guard settingsStore.settings.advanced.showPRStatusInSidebar else { return nil }
        let container: ContainerID? = switch kind {
        case let .projectHeader(project, _):
            .project(project.id)
        case let .worktree(projectID, worktree):
            .worktree(projectID: projectID, worktreeID: worktree.id)
        case .loose, .group:
            nil
        }
        guard let container, let info = prStatusStore.info(for: container) else { return nil }
        return (container, info)
    }

    /// Whether the row draws its pull-request mark at rest.
    ///
    /// Gating here rather than in `PRMarkPresentation` keeps that
    /// mapping a pure function of the request and leaves the hover
    /// card alone — `prHoverCardTarget` still resolves on every row
    /// with a request.
    /// What counts as attention lives on `PRInfo`, so it is testable
    /// without standing up a view.
    private var showsPRMark: Bool {
        guard let info = prHoverCardTarget?.info else { return false }
        guard settingsStore.settings.advanced.showPRStatusOnlyWhenAttention else { return true }
        return info.needsAttention
    }

    /// Pull-request mark. Sits in the trailing group so the
    /// leading marker stays free to say what the row *is* — see
    /// `PRMarkPresentation` for why that separation matters here.
    private func prStatusMark(_ style: PRMarkPresentation) -> some View {
        // A bundled Octicon, not an SF Symbol, so it is sized by frame
        // rather than by font — see `PRMarkPresentation` for why the glyphs
        // are assets.
        Image(style.glyph)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(
                width: LimpidLayout.containerColumnPRGlyphSize,
                height: LimpidLayout.containerColumnPRGlyphSize
            )
            .foregroundStyle(style.tint)
            .frame(width: LimpidLayout.containerColumnTrailingSlot, height: LimpidLayout.containerColumnTrailingSlot)
            .overlay(alignment: .bottomTrailing) {
                if let badge = style.badge {
                    // The mark is cut out of the disc, so the circle
                    // behind is what shows through it — and being one
                    // drawing, it is exactly centerd, where the SF
                    // Symbol this replaced landed its two layers a
                    // fraction of a pixel apart at this size.
                    //
                    // Hidden from VoiceOver; its meaning is spoken
                    // through the value below.
                    Circle()
                        .fill(LimpidColor.statusGlyphKnockout)
                        .overlay {
                            Image(badge.glyph)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(badge.color)
                        }
                        .frame(width: 9, height: 9)
                        .offset(x: 2, y: 2)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(Text(style.accessibilityKey))
            // A failing check is a red mark and nothing else on screen.
            // Speaking it here is what keeps that meaning off color.
            .accessibilityValue(style.badge.map { Text($0.accessibilityKey) } ?? Text(verbatim: ""))
    }

    /// Trailing accessory — the row's status column. Read outward from
    /// the label: the missing-worktree warning, the hover-only
    /// new-worktree button, then the standing trio of pull request,
    /// agent state and bell. Only the bell reserves its slot, so the
    /// group's right edge is fixed while at rest and the rest stack
    /// inward from it.
    ///
    /// New-worktree and the Group delete appear on hover, reflowing
    /// the label by a slot while the pointer is on the row. Holding
    /// slots for them instead is what made the group's right edge
    /// depend on the row kind — see the file banner.
    private var trailingAccessory: some View {
        HStack(spacing: LimpidLayout.containerColumnTrailingSpacing) {
            if isMissingWorktree {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("Worktree not found on disk")
            }
            if isHovering, !isEditing, let onCreateWorktree {
                // Create-worktree (Y) stays inside the trailing group
                // — it sits next to the project header it belongs to
                // rather than at the row edge, so it stays inside the
                // status column's rhythm instead of hanging off it.
                Button(action: onCreateWorktree) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: LimpidLayout.containerColumnTrailingSlot, height: LimpidLayout.containerColumnTrailingSlot)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Worktree…")
            }
            // The request comes before the agent, reading outward from
            // the label: what this branch *is* proposing, then what is
            // happening in it right now. The agent state changes by the
            // second and the request by the day, so the volatile one
            // sits nearer the edge where the eye already goes for the
            // bell.
            if showsPRMark,
               let style = PRMarkPresentation.style(for: prHoverCardTarget?.info, accent: limpidAccent)
            {
                prStatusMark(style)
            }
            if let state = agentState,
               let iconName = state.iconName,
               let iconColor = state.iconColor
            {
                let tooltip = agentTooltip(for: state)
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: LimpidLayout.containerColumnTrailingSlot, height: LimpidLayout.containerColumnTrailingSlot)
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
            // Present only while hovered, and it holds no slot the
            // rest of the time. The previous version reserved one
            // permanently to keep the row's right edge from shifting,
            // which froze a gap into every row that had a delete and
            // left the ones without — Quick Tabs — ending short. At
            // rest is when the column gets read, so it wins; the hover
            // reflow is the same trade `onCreateWorktree` above makes.
            if let onDelete, kind.allowsHoverDelete, isHovering, !isEditing {
                Button(action: onDelete) {
                    Image(systemName: closeIcon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: LimpidLayout.containerColumnTrailingSlot,
                            height: LimpidLayout.containerColumnTrailingSlot
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(closeLabel))
                .accessibilityLabel(Text(closeLabel))
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

    // MARK: - Kind forwarding

    /// `closeLabel` / `closeIcon` are kind-derived and live on
    /// `ContainerRowKind` (top of this file) so the view's struct body
    /// stays within the lint length budget.
    private var closeLabel: LocalizedStringResource {
        kind.closeLabel
    }

    private var closeIcon: String {
        kind.closeIcon
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
