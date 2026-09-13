// ContainerSlabView.swift
// Limpid — the container column sidebar slab. A `VerticalSplitView`
// divides it into the scrolling container list — the Quick Tabs row
// pinned at the top above two collapsible sections (Groups / Projects) —
// and the Waiting region below.
// Section headers carry the fold chevron; individual
// rows are foldable per-project only. Every
// reorderable / droppable row uses the shared
// `reorderableDropTarget(...)` modifier so the drop animation stays
// identical to the tab column's reorder.

import AppKit
import SwiftUI

struct ContainerSlabView: View {
    /// The slab remains mounted while the sidebar is offscreen, but hidden
    /// content must not respond to commands or retain modal presentation.
    let isPresentationEnabled: Bool
    /// Owned by the window so explicit commands can present while the slab is
    /// disabled offscreen; visible row actions write through the same binding.
    @Binding var creatingWorktreeFor: UUID?
    @Environment(WindowSession.self) private var session
    @Environment(AttentionState.self) private var attention
    @Environment(ApprovalPresentationStore.self) private var approvalPresentation
    @Environment(LimpidDragState.self) private var dragState
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.limpidAccent) var limpidAccent
    // Read only to hand back down through `slabEnvironment` — the
    // rows below need them, the slab itself does not.
    @Environment(PRStatusStore.self) private var prStatusStore
    @Environment(PRHoverPresentation.self) private var prHoverPresentation
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.prStatusSyncer) private var prStatusSyncer

    /// Container (Project or Group) whose Settings sheet should be
    /// presented, if any. One sheet serves both kinds.
    @State private var openSettingsFor: ContainerSettingsTarget?
    /// Pending "Delete Worktree" target. Presents a confirmation alert
    /// before invoking git. Force-retry state lives separately so the
    /// alert can offer a one-click escalation when git rejects the
    /// initial attempt for dirty trees.
    @State private var deletingWorktree: DeleteWorktreeTarget?
    @State private var forceDeleteWorktree: DeleteWorktreeTarget?
    /// Pending "Close Project" / "Close Group" targets. Both surface a
    /// confirmation alert because the action closes every tab nested
    /// under the entity — non-trivial loss if invoked by mistake.
    @State private var removingProject: RemoveProjectTarget?
    @State private var removingGroup: RemoveGroupTarget?
    /// Shared error surface for any worktree operation (create /
    /// rename / delete / hide). One alert, one state — keeps the
    /// failure UI honest no matter which pipeline threw.
    @State private var worktreeOperationError: String?

    var body: some View {
        VerticalSplitView(
            topMinHeight: LimpidLayout.containerListMinHeight,
            bottomMinHeight: LimpidLayout.attentionMinHeight,
            bottomFractionRange: LimpidLayout.attentionMinFraction...LimpidLayout.attentionMaxFraction,
            bottomInitialFraction: session.attentionHeightFraction,
            bottomDefaultFraction: LimpidLayout.attentionHeightFraction,
            onBottomFractionChanged: { fraction in
                persistAttentionFraction(fraction)
            },
            top: { slabEnvironment(containerList) },
            bottom: { slabEnvironment(attentionRegion) }
        )
        // Breathing room between the Waiting region (or any container
        // column content) and the slab's bottom edge.
        .padding(.bottom, 12)
        // The slab stays mounted offscreen so its slide-out can complete.
        // Disabling the subtree also tells an active inline rename to
        // finalize and release the window's shared field editor.
        .disabled(!isPresentationEnabled)
        .sheet(item: presentationBinding($openSettingsFor)) { target in
            ContainerSettingsSheet(target: target)
                .environment(session)
                .limpidAccentPropagated(limpidAccent)
        }
        .worktreeOperationAlerts(
            deletingWorktree: presentationBinding($deletingWorktree),
            forceDeleteWorktree: presentationBinding($forceDeleteWorktree),
            removingProject: presentationBinding($removingProject),
            removingGroup: presentationBinding($removingGroup),
            worktreeOperationError: presentationBinding($worktreeOperationError)
        )
        .onChange(of: isPresentationEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            dismissPresentations()
        }
    }

    private func dismissPresentations() {
        openSettingsFor = nil
        deletingWorktree = nil
        forceDeleteWorktree = nil
        removingProject = nil
        removingGroup = nil
        worktreeOperationError = nil
    }

    /// Keep delayed operation results while hidden, but do not let the
    /// offscreen slab present them. Reopening reveals the pending result.
    private func presentationBinding<Value>(_ source: Binding<Value?>) -> Binding<Value?> {
        Binding(
            get: { isPresentationEnabled ? source.wrappedValue : nil },
            set: { source.wrappedValue = $0 }
        )
    }

    /// Target of a "Delete Worktree…" gesture. Carries enough context
    /// for the confirmation alert + Force retry. Lives at slab level
    /// because the alert state is owned here, but `ProjectSectionView`
    /// constructs instances when the user invokes the menu entry.
    struct DeleteWorktreeTarget: Identifiable, Equatable {
        let id = UUID()
        let projectID: UUID
        let worktreeID: UUID
        let label: String
        let path: URL
    }

    /// Target of a "Close Project" gesture.
    struct RemoveProjectTarget: Identifiable, Equatable {
        let id = UUID()
        let projectID: UUID
        let name: String
    }

    /// Target of a "Close Group" gesture.
    struct RemoveGroupTarget: Identifiable, Equatable {
        let id = UUID()
        let groupID: UUID
        let name: String
    }

    /// Value-typed signature SwiftUI compares to decide whether the
    /// `.animation(value:)` modifier should run. The previous shape
    /// joined per-project UUID/Bool pairs into one `String`, allocating
    /// a fresh array + string on every body re-eval. SwiftUI only
    /// needs equality — a `Hashable` triple does the same job without
    /// the per-render allocations.
    private struct FoldSignature: Hashable {
        let groupsExpanded: Bool
        let projectsExpanded: Bool
        let projectStates: [Bool]
    }

    private var foldSignature: FoldSignature {
        FoldSignature(
            groupsExpanded: session.groupsSectionExpanded,
            projectsExpanded: session.projectsSectionExpanded,
            projectStates: session.projects.map(\.isExpanded)
        )
    }

    /// Height the Groups section occupies below its header when open.
    private var groupsSectionHeight: CGFloat {
        Self.stackedHeight(session.groups.map { _ in LimpidLayout.containerColumnRowHeight })
    }

    /// Height the Projects section occupies below its header when
    /// open. Each project reports its own because an expanded one also
    /// carries its worktrees.
    private var projectsSectionHeight: CGFloat {
        Self.stackedHeight(session.projects.map(ProjectSectionView.blockHeight(for:)))
    }

    /// Sum of stacked block heights, the gaps between them, and the
    /// gap above the first — which belongs to the section rather than
    /// to the enclosing list; see `FoldableSection`. Zero for no
    /// blocks, so an empty section occupies exactly its header.
    ///
    /// Static and internal because this is one half of an agreement
    /// nothing else checks: the leading gap has to match the
    /// `.padding(.top,)` inside `FoldableSection`, and a test is the
    /// only place that can hold the two together.
    static func stackedHeight(_ blocks: [CGFloat]) -> CGFloat {
        guard !blocks.isEmpty else { return 0 }
        return LimpidLayout.reorderRowSpacing
            + blocks.reduce(0, +)
            + CGFloat(blocks.count - 1) * LimpidLayout.reorderRowSpacing
    }

    // MARK: - Section header

    /// The lower pane of the slab's split: always present (even with
    /// nothing waiting) so the user has a stable place to glance. It
    /// lists every pane the agent is waiting on the user for
    /// (needsInput / error / finished) in the same order the ⌘J cursor
    /// walks; the inner area scrolls when the list overflows. Tapping a
    /// row jumps focus to that pane.
    @ViewBuilder
    private var attentionRegion: some View {
        // The pane the user is currently looking at — its row gets a
        // highlight so "where am I" is obvious while cycling with ⌘J.
        let focusedTab = session.activeTabID
        let focusedPane = session.activeTab?.splitTree.focusedLeafID
        // TimelineView re-renders once per minute. The label is
        // "just now" under 60s and steps to "1m / 2m / …" from there
        // — so second-grain ticking would only be visible flicker.
        // 60s keeps the m/h/d label honest without churning the slab.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            // The list itself is derived inside the tick, not outside
            // it: a viewed finished turn drops out once it ages past
            // `AttentionState.viewedFinishedRetention`, and that rule
            // reads the wall clock. Evaluated above the TimelineView,
            // an aged-out row would stay listed until some unrelated
            // state change happened to re-render the slab.
            let approvals = approvalPresentation.pending
            // Claude may emit its legacy permission notification alongside a
            // PermissionRequest. Once the authenticated request maps to that
            // pane, show only the broker-owned row so one prompt never has two
            // visible owners.
            let nativeApprovalPaneIDs = Set(approvals.compactMap {
                approvalPresentation.paneLocation(for: $0, in: session)?.1
            })
            let entries = attention.attentionEntries(in: session).filter {
                $0.state != .needsInput || !nativeApprovalPaneIDs.contains($0.paneID)
            }
            // The header carries the per-state counts, so it belongs
            // inside the tick as well.
            VStack(alignment: .leading, spacing: 0) {
                attentionHeader(
                    entries: entries,
                    approvalCount: approvals.count,
                    attention: attention
                )
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if entries.isEmpty, approvals.isEmpty {
                            // Two empty-state messages so the region is
                            // never a silent blank rectangle:
                            //   - filter on + things hidden → "N hidden"
                            //   - everything else → "All clear" (inbox
                            //     zero feels intentional, not broken)
                            // Calm wording, no affordance — the filter
                            // in the header is the user's way back.
                            //
                            // Branches are kept separate (not a ternary)
                            // so each `Text(_:)` call resolves to the
                            // `LocalizedStringKey` overload — a ternary
                            // collapses to `String`, which `Text` treats
                            // as verbatim and never localizes.
                            let hidden = attention.hiddenViewedCount(in: session)
                            Group {
                                if hidden > 0 {
                                    Text("\(hidden) hidden by filter")
                                } else {
                                    Text("All clear")
                                }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 4)
                        }
                        ForEach(approvals) { approval in
                            let location = approvalPresentation.paneLocation(for: approval, in: session)
                            ApprovalAttentionRow(
                                approval: approval,
                                isResolving: approvalPresentation.resolvingIDs.contains(approval.id),
                                onAllow: { approvalPresentation.resolve(approval, decision: "allow_once") },
                                onDeny: { approvalPresentation.resolve(approval, decision: "deny") },
                                onTap: {
                                    guard let location else { return }
                                    attention.focusAttention(
                                        in: session,
                                        registry: registry,
                                        tabID: location.0,
                                        paneID: location.1
                                    )
                                }
                            )
                        }
                        ForEach(entries) { entry in
                            if let tab = session.tab(entry.tabID) {
                                AttentionRow(
                                    timestamp: entry.updatedAt,
                                    now: context.date,
                                    state: entry.state,
                                    containerLabel: session.containerLabel(for: tab.container),
                                    tabTitle: tab.displayTitle,
                                    prompt: attentionPreview(entry),
                                    isCurrent: entry.tabID == focusedTab && entry.paneID == focusedPane,
                                    onDismiss: entry.state == .finished
                                        ? {
                                            if let id = entry.runtimeID {
                                                attention.dismissRuntime(id)
                                            } else {
                                                attention.dismiss(paneID: entry.paneID, in: session)
                                            }
                                        }
                                        : nil
                                ) {
                                    attention.focusAttention(
                                        in: session,
                                        registry: registry,
                                        tabID: entry.tabID,
                                        paneID: entry.paneID,
                                        runtimeID: entry.runtimeID
                                    )
                                }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    /// The scrolling upper pane of the slab: Quick Tabs, Groups,
    /// Projects. Extracted from `body` so the split view's two panes
    /// read as a pair at the call site.
    private var containerList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: LimpidLayout.reorderRowSpacing) {
                // "Quick Tabs" sits alone at the top — no section header
                // since it'd just label a single row. Sections only kick
                // in when there's an actual list to label (Groups,
                // Projects).
                ContainerRow(
                    kind: .loose,
                    isActive: isActiveContainer(.loose),
                    hasUnread: hasUnread(in: .loose),
                    isRinging: isRinging(in: .loose),
                    agentState: agentState(in: .loose),
                    agentBreakdown: agentBreakdown(in: .loose),
                    onActivate: { session.setActiveContainer(.loose) },
                    onToggleExpand: nil,
                    onRename: nil
                )
                .reorderableDropTarget(
                    targetID: "loose",
                    acceptedPrefixes: ["tab:"],
                    tabAsContainerAssignment: true,
                    isNoOp: { sourceID, _ in
                        guard let src = session.tab(sourceID) else { return false }
                        return src.container == .loose
                    },
                    onDrop: { _, sourceID, _ in
                        session.moveTab(sourceID, to: .loose)
                    }
                )

                // Folded by clipping the section to a height rather
                // than inserting its rows — see `FoldableSection`.
                FoldableSection(
                    isExpanded: session.groupsSectionExpanded,
                    height: groupsSectionHeight
                ) {
                    sectionHeader(
                        "GROUPS",
                        isExpanded: session.groupsSectionExpanded,
                        toggle: {
                            withAnimation(LimpidMotion.reorder) {
                                session.groupsSectionExpanded.toggle()
                            }
                        },
                        addAccessory: {
                            AnyView(
                                Button {
                                    withAnimation(LimpidMotion.reorder) {
                                        session.groupsSectionExpanded = true
                                        _ = session.addGroup()
                                    }
                                } label: {
                                    SectionAddBadge()
                                }
                                .buttonStyle(.plain)
                                .help("New Group")
                                .accessibilityLabel(Text("New Group"))
                            )
                        }
                    )
                } content: {
                    VStack(alignment: .leading, spacing: LimpidLayout.reorderRowSpacing) {
                        ForEach(session.groups) { group in
                            ContainerRow(
                                kind: .group(group, isExpanded: false),
                                isActive: isActiveContainer(.group(group.id)),
                                hasUnread: hasUnread(in: .group(group.id)),
                                isRinging: isRinging(in: .group(group.id)),
                                agentState: agentState(in: .group(group.id)),
                                agentBreakdown: agentBreakdown(in: .group(group.id)),
                                onActivate: { session.setActiveContainer(.group(group.id)) },
                                onToggleExpand: nil,
                                onRename: { session.renameGroup(group.id, to: $0) },
                                actions: ContainerRowActions(
                                    onDelete: {
                                        // Empty groups (0 tabs) skip
                                        // the confirm modal — there's
                                        // nothing to lose, so the alert
                                        // would just be friction.
                                        if session.tabs(in: group.id).isEmpty {
                                            withAnimation(LimpidMotion.reorder) {
                                                ContainerActions.removeGroup(
                                                    session,
                                                    registry: registry,
                                                    groupID: group.id
                                                )
                                            }
                                        } else {
                                            removingGroup = RemoveGroupTarget(
                                                groupID: group.id,
                                                name: group.name
                                            )
                                        }
                                    },
                                    onChangePalette: { idx in
                                        session.setGroupPaletteIndex(group.id, to: idx)
                                    },
                                    onMoveUp: {
                                        withAnimation(LimpidMotion.reorder) {
                                            session.moveGroupUp(group.id)
                                        }
                                    },
                                    onMoveDown: {
                                        withAnimation(LimpidMotion.reorder) {
                                            session.moveGroupDown(group.id)
                                        }
                                    },
                                    canMoveUp: session.canMoveGroupUp(group.id),
                                    canMoveDown: session.canMoveGroupDown(group.id),
                                    onOpenSettings: { openSettingsFor = .group(group.id) }
                                ),
                                // Drag must attach from inside the
                                // row body so the row's tap /
                                // context-menu gestures don't claim
                                // the hit area first on macOS 26.
                                dragDescriptor: ContainerRow.DragDescriptor(
                                    kind: .group,
                                    prefix: "group:",
                                    id: group.id.uuidString,
                                    dragState: dragState
                                )
                            )
                            .reorderableDropTarget(
                                targetID: "group-\(group.id)",
                                acceptedPrefixes: ["tab:", "group:"],
                                tabAsContainerAssignment: true,
                                isNoOp: { sourceID, position in
                                    // Tab cross-move into the same group
                                    // = no-op (bg highlight suppressed).
                                    if let src = session.tab(sourceID),
                                       case let .group(gid) = src.container, gid == group.id
                                    {
                                        return true
                                    }
                                    // Self-drop: dragging this group onto
                                    // its own row never moves anything.
                                    if sourceID == group.id {
                                        return true
                                    }
                                    // Group reorder adjacency check —
                                    // dropping right next to where the
                                    // source already sits is a no-op.
                                    guard let srcIdx = session.groups.firstIndex(where: { $0.id == sourceID }),
                                          let tgtIdx = session.groups.firstIndex(where: { $0.id == group.id })
                                    else { return false }
                                    switch position {
                                    case .before: return srcIdx == tgtIdx - 1
                                    case .after: return srcIdx == tgtIdx + 1
                                    }
                                },
                                onDrop: { prefix, sourceID, position in
                                    if prefix == "tab:" {
                                        session.moveTab(sourceID, to: .group(group.id))
                                    } else if prefix == "group:" {
                                        session.reorderGroup(sourceID: sourceID, target: group.id, position: position)
                                    }
                                }
                            )
                        }
                    }
                }

                // Same treatment as GROUPS above.
                FoldableSection(
                    isExpanded: session.projectsSectionExpanded,
                    height: projectsSectionHeight
                ) {
                    sectionHeader(
                        "PROJECTS",
                        isExpanded: session.projectsSectionExpanded,
                        toggle: {
                            withAnimation(LimpidMotion.reorder) {
                                session.projectsSectionExpanded.toggle()
                            }
                        },
                        addAccessory: {
                            AnyView(
                                ProjectAddMenu(
                                    recentPaths: session.recentProjectPaths,
                                    onOpenFolder: { openProjectFolderPicker() },
                                    onOpenRecent: { url in openProject(at: url) }
                                )
                            )
                        }
                    )
                } content: {
                    VStack(alignment: .leading, spacing: LimpidLayout.reorderRowSpacing) {
                        ForEach(session.projects) { project in
                            ProjectSectionView(
                                project: project,
                                creatingWorktreeFor: $creatingWorktreeFor,
                                openSettingsFor: $openSettingsFor,
                                deletingWorktree: $deletingWorktree,
                                removingProject: $removingProject,
                                worktreeOperationError: $worktreeOperationError
                            )
                        }
                    }
                }
            }
            // The same inset the tab list and the horizontal strip
            // take, so the first row of every list lands on one line.
            .padding(.vertical, LimpidLayout.rowListInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(LimpidMotion.expand, value: foldSignature)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// Mirror a divider drag or double-click reset onto the stored
    /// value. `NSSplitView` can autosave divider positions itself, but
    /// the share belongs with the rest of the window session rather than
    /// in `UserDefaults`. No clamping here: `VerticalSplitView`
    /// constrains the drag and hands back only user-driven shares. The
    /// dead-band keeps a drag's stream of callbacks from rewriting the
    /// session on every frame.
    private func persistAttentionFraction(_ fraction: CGFloat) {
        if abs(fraction - session.attentionHeightFraction) > 0.005 {
            session.attentionHeightFraction = fraction
        }
    }

    /// The panes do inherit this view's SwiftUI environment through the
    /// representable — verified by rendering the slab without this
    /// helper — but the slab's correctness shouldn't rest on that, so we
    /// re-apply every value the subtree reads. Add new ones in this one
    /// place.
    private func slabEnvironment(_ content: some View) -> some View {
        content
            .environment(session)
            .environment(attention)
            .environment(approvalPresentation)
            .environment(dragState)
            .environment(toastCenter)
            .environment(prStatusStore)
            .environment(prHoverPresentation)
            .environment(settingsStore)
            .environment(\.prStatusSyncer, prStatusSyncer)
            .environment(\.surfaceRegistry, registry)
            .limpidAccentPropagated(limpidAccent)
            // `VerticalSplitView` hosts each pane in its own `NSHostingView`.
            // Reapply disabled state at that boundary so inline editors
            // reliably release focus when the offscreen slab closes.
            .disabled(!isPresentationEnabled)
    }

    private func sectionHeader(
        _ title: String,
        isExpanded: Bool?,
        toggle: @escaping () -> Void,
        addAccessory: (() -> AnyView)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color.primary.opacity(0.55))
            Spacer()
            // `+` sits just left of the section's own fold chevron.
            // Both are section furniture and share the header's
            // trailing padding with the rows' status column below.
            if let addAccessory {
                addAccessory()
            }
            if let isExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: LimpidLayout.containerColumnTrailingSlot, height: LimpidLayout.containerColumnTrailingSlot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isExpanded != nil {
                toggle()
            }
        }
    }

    // MARK: - Project add helpers

    /// Opens an `NSOpenPanel` for the user to pick a folder and adds
    /// it as a Project (or activates the existing one).
    private func openProjectFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.message = String(localized: "Choose a folder to open as a Project.")
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // Non-blocking variant of `runModal`; the completion fires on
        // main once the user dismisses the panel. See
        // `WorkingDirectoryField.chooseDirectory` for the stutter
        // rationale.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            openProject(at: url)
        }
    }

    private func openProject(at url: URL) {
        // Resolve linked-worktree paths to the main checkout before
        // handing off to the session — otherwise a Project added by
        // pointing at `/repo-feature-x` ends up self-referencing
        // inside its own `git worktree list` output. The resolver
        // returns `url` unchanged for non-git folders, main
        // checkouts, and arbitrary subdirectories, so wrapping every
        // call in the Task is harmless for those paths.
        Task { @MainActor in
            let resolved = await GitProcess.resolveMainCheckout(of: url)
            withAnimation(LimpidMotion.reorder) {
                session.projectsSectionExpanded = true
            }
            let project = session.addOrActivateProject(rootURL: resolved)
            if session.tabs.first(where: { $0.projectID == project.id }) == nil {
                session.openTab(container: .project(project.id))
            }
        }
    }

    // MARK: - Active / unread helpers

    private func isActiveContainer(_ c: ContainerID) -> Bool {
        session.activeContainerID == c
    }

    private func isActiveProject(_ projectID: UUID) -> Bool {
        session.activeContainerID.projectID == projectID
    }

    private func hasUnread(in container: ContainerID) -> Bool {
        session.hasUnread(in: container)
    }

    private func hasUnreadInProject(_ projectID: UUID) -> Bool {
        session.hasUnreadInProject(projectID)
    }

    private func isRinging(in container: ContainerID) -> Bool {
        session.isRinging(in: container)
    }

    private func isRingingInProject(_ projectID: UUID) -> Bool {
        session.isRingingInProject(projectID)
    }

    fileprivate func agentState(in container: ContainerID) -> AgentState? {
        attention.aggregateAgentState(in: container, session: session)
    }

    fileprivate func agentBreakdown(in container: ContainerID) -> [AgentState: Int] {
        attention.agentStateBreakdown(in: container, session: session)
    }

}

/// `+` next to the PROJECTS section header. Shows a `Menu` so the
/// user can pick a recent project or open a folder picker — bundling
/// both behind one affordance preserves the Recent-Projects shortcut
/// that lived in the old toolbar `+` menu.
private struct ProjectAddMenu: View {
    let recentPaths: [URL]
    let onOpenFolder: () -> Void
    let onOpenRecent: (URL) -> Void

    var body: some View {
        Menu {
            if !recentPaths.isEmpty {
                Section("Recent") {
                    ForEach(recentPaths.prefix(8), id: \.self) { url in
                        Button {
                            onOpenRecent(url)
                        } label: {
                            Label(
                                "\(url.lastPathComponent) — \(url.path)",
                                systemImage: "clock"
                            )
                        }
                    }
                }
            }
            Button(action: onOpenFolder) {
                Label("Open Folder as Project…", systemImage: "folder.badge.gearshape")
            }
        } label: {
            SectionAddBadge()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("New Project")
        .accessibilityLabel(Text("New Project"))
    }
}

/// Filled circle badge with a `+` glyph — used as the visual for the
/// GROUPS / PROJECTS section-header add affordance. Reads as a
/// solid, always-on button (vs the chevron's text-weight glyph)
/// without resorting to a full Toolbar capsule shape.
private struct SectionAddBadge: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(LimpidColor.rowHoverFill)
            )
            .contentShape(Circle())
    }
}

/// A collapsible section's rows, clipped to a height that goes to
/// zero while the section is folded.
///
/// Inserting and removing them under a `.transition` did not work:
/// the transition never ran, so the rows appeared at their final
/// position while everything below was still sliding down and the two
/// drew on top of each other. Clipping to a height leaves no insertion
/// to overlap. See `ProjectSectionView.worktreeStack` for what was
/// tried and for why the obvious explanation does not hold.
///
/// The fold is instant, which is a known limitation rather than an
/// intent — the identical construction in `ProjectSectionView` does
/// interpolate, and neither an own `View`, an explicit
/// `.animation(value:)`, nor an eager enclosing stack changed it
/// here. Instant is plain but correct; the overlap was not.
///
/// The rows stay mounted while folded, so hit testing and VoiceOver
/// are switched off with them. That also means the enclosing
/// `LazyVStack` no longer skips a folded section's rows the way an
/// `if` would: laziness now works at section granularity, which is the
/// standing cost of folding this way.
private struct FoldableSection<Header: View, Content: View>: View {
    let isExpanded: Bool
    let height: CGFloat
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        // The header and the body are one child of the enclosing list,
        // and the gap above the first row lives inside the clip rather
        // than coming from the list's own spacing. Holding the header
        // outside would leave the body a child of its own, and a folded
        // one is a child at zero height: the list would then put its
        // spacing on both sides of nothing, doubling the gap between
        // two headers whenever a section is folded or empty.
        // `ProjectSectionView.worktreeStack` folds the same way for the
        // same reason.
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .padding(.top, LimpidLayout.reorderRowSpacing)
                .frame(height: isExpanded ? height : 0, alignment: .top)
                .clipped()
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
