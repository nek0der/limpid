// ContainerSlabView.swift
// Limpid — the L1 sidebar slab. Renders three sections (Tabs / Groups
// / Projects). Section headers carry the fold chevron; individual
// rows are foldable per-project only (worktrees + general). Every
// reorderable / droppable row uses the shared
// `reorderableDropTarget(...)` modifier so the insertion line + drop
// animation stay identical to the L2 tab reorder.

import AppKit
import SwiftUI

struct ContainerSlabView: View {
    @Environment(WindowSession.self) private var session
    @Environment(TriageState.self) private var triage
    @Environment(LimpidDragState.self) private var dragState
    @Environment(\.surfaceRegistry) private var registry

    /// Project whose Create-Worktree sheet should be presented, if any.
    @State private var creatingWorktreeFor: UUID?
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
        @Bindable var session = session
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: LimpidLayout.reorderRowSpacing) {
                        // "Quick Tabs" sits alone at the top — no section header
                        // since it'd just label a single row. Sections only kick
                        // in when there's an actual list to label (Groups,
                        // Projects).
                        ContainerRow(
                            kind: .loose(count: session.looseTabs.count),
                            isActive: isActiveContainer(.loose),
                            hasUnread: hasUnread(in: .loose),
                            isRinging: isRinging(in: .loose),
                            agentState: agentState(in: .loose),
                            agentStateViewed: triage.isFinishedAggregateViewed(in: .loose, session: session),
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
                                )
                            }
                        )
                        if session.groupsSectionExpanded {
                            Group {
                                ForEach(session.groups) { group in
                                    ContainerRow(
                                        kind: .group(
                                            group,
                                            count: session.tabs(in: group.id).count,
                                            isExpanded: false
                                        ),
                                        isActive: isActiveContainer(.group(group.id)),
                                        hasUnread: hasUnread(in: .group(group.id)),
                                        isRinging: isRinging(in: .group(group.id)),
                                        agentState: agentState(in: .group(group.id)),
                                        agentStateViewed: triage.isFinishedAggregateViewed(in: .group(group.id), session: session),
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
                                                        TabActions.removeGroup(
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
                                            if sourceID == group.id { return true }
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
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

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
                        if session.projectsSectionExpanded {
                            Group {
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
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.easeInOut(duration: 0.2), value: foldSignature)
                }
                // Take all remaining height so the WAITING region
                // below is pinned to the bottom of the slab (otherwise
                // the VStack top-aligns the scroll view and the region
                // floats up / off-screen).
                .frame(maxHeight: .infinity)
                attentionRegion(slabHeight: proxy.size.height)
            }
            // Breathing room between the WAITING region (or any L1
            // content) and the slab's bottom edge — without this the
            // last WAITING row hugs the frame and reads as cropped.
            .padding(.bottom, 12)
        }
        .sheet(item: Binding(
            get: { creatingWorktreeFor.map { IdentifiedUUID(id: $0) } },
            set: { creatingWorktreeFor = $0?.id }
        )) { wrapped in
            CreateWorktreeSheet(projectID: wrapped.id)
                .environment(session)
        }
        .sheet(item: $openSettingsFor) { target in
            ContainerSettingsSheet(target: target)
                .environment(session)
        }
        .worktreeOperationAlerts(
            deletingWorktree: $deletingWorktree,
            forceDeleteWorktree: $forceDeleteWorktree,
            removingProject: $removingProject,
            removingGroup: $removingGroup,
            worktreeOperationError: $worktreeOperationError
        )
        .onReceive(NotificationCenter.default.publisher(for: .limpidCreateWorktreeRequested)) { _ in
            // Triggered by ⌘⌥W. Routes to the active project; if the
            // user is not on a project, falls back to the first one.
            if let pid = session.activeContainerID.projectID
                ?? session.projects.first?.id
            {
                creatingWorktreeFor = pid
            }
        }
    }

    /// Wrapper so we can drive `.sheet(item:)` from a plain UUID.
    private struct IdentifiedUUID: Identifiable, Equatable { let id: UUID }

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

    private var foldSignature: String {
        let projectStates = session.projects.map { "\($0.id):\($0.isExpanded)" }.joined(separator: ",")
        return "\(session.groupsSectionExpanded)|\(session.projectsSectionExpanded)|\(projectStates)"
    }

    // MARK: - Section header

    /// Bottom-of-slab triage region, pinned at a fraction of the slab
    /// height and always present (even with nothing waiting) so the user
    /// has a stable place to glance. A grey rule (also the resize handle)
    /// separates it from the Quick Tabs / Groups / Projects list above; it
    /// lists every pane the agent is waiting on the user for (needsInput /
    /// error / finished) in the same order the ⌘J cursor walks; the inner
    /// area scrolls when the list overflows. Tapping a row jumps focus to
    /// that pane.
    @ViewBuilder
    private func attentionRegion(slabHeight: CGFloat) -> some View {
        @Bindable var session = session
        let entries = triage.attentionEntries(in: session)
        // The pane the user is currently looking at — its row gets a
        // highlight so "where am I" is obvious while cycling with ⌘J.
        let focusedTab = session.activeTabID
        let focusedPane = session.activeTab?.splitTree.focusedLeafID
        // Floor to `attentionMinHeight` so the 0-item hint ("All clear"
        // / "N hidden") stays visible even when the user has dragged the
        // region to its smallest fraction in a short sidebar.
        let height = max(slabHeight * session.attentionHeightFraction, LimpidLayout.attentionMinHeight)
        VStack(alignment: .leading, spacing: 0) {
            // Grey rule doubles as the drag handle: drag up/down to
            // resize the region, double-click to reset to the default
            // fraction. Stored as a fraction of slab height so it keeps
            // its proportion across window resizes.
            AttentionDividerHandle(
                currentFraction: { session.attentionHeightFraction },
                setFraction: { session.attentionHeightFraction = $0 },
                slabHeight: slabHeight
            )
            attentionHeader(count: entries.count, triage: triage)
            // TimelineView re-renders once per minute. The label is
            // "just now" under 60s and steps to "1m / 2m / …" from there
            // — so second-grain ticking would only be visible flicker.
            // 60s keeps the m/h/d label honest without churning the slab.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if entries.isEmpty {
                            // Two empty-state messages so the region is
                            // never a silent blank rectangle:
                            //   - filter on + things hidden → "N hidden"
                            //   - everything else → "All clear" (inbox
                            //     zero feels intentional, not broken)
                            // Calm wording, no affordance — the eye in
                            // the header is the user's way back.
                            //
                            // Branches are kept separate (not a ternary)
                            // so each `Text(_:)` call resolves to the
                            // `LocalizedStringKey` overload — a ternary
                            // collapses to `String`, which `Text` treats
                            // as verbatim and never localizes.
                            let hidden = triage.hiddenViewedCount(in: session)
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
                        ForEach(entries) { entry in
                            if let tab = session.tab(entry.tabID) {
                                AttentionRow(
                                    timestamp: entry.updatedAt,
                                    now: context.date,
                                    containerLabel: session.containerLabel(for: tab.container),
                                    containerColor: containerColor(for: tab.container),
                                    containerIcon: containerIcon(for: tab.container),
                                    tabTitle: tab.displayTitle,
                                    prompt: attentionPreview(entry),
                                    isCurrent: entry.tabID == focusedTab && entry.paneID == focusedPane,
                                    isViewed: entry.isViewed,
                                    onDismiss: entry.state == .finished
                                        ? { triage.dismiss(paneID: entry.paneID, in: session) }
                                        : nil
                                ) {
                                    triage.focusAttention(
                                        in: session,
                                        registry: registry,
                                        tabID: entry.tabID,
                                        paneID: entry.paneID
                                    )
                                }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
        .frame(height: height, alignment: .top)
    }

    /// Palette colour of a container, for the WAITING row's dot.
    /// `.loose` (Quick Tabs) has no palette, so it falls back to the
    /// neutral default colour.
    private func containerColor(for container: ContainerID) -> Color {
        switch container {
        case .loose:
            LimpidColor.paletteColor(nil)
        case let .group(gid):
            LimpidColor.paletteColor(session.group(gid)?.paletteIndex)
        case let .project(pid):
            LimpidColor.paletteColor(session.project(pid)?.paletteIndex)
        case let .worktree(pid, _):
            LimpidColor.paletteColor(session.project(pid)?.paletteIndex)
        }
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
            // `+` sits adjacent to the chevron (matching the row's
            // create-worktree `Y` column — second from the right in
            // hover state, just left of `countOrChevron`). The bell
            // is hidden on rows without unread notifications, so
            // there's no gap to reserve between `+` and chevron.
            if let addAccessory {
                addAccessory()
            }
            if let isExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { if isExpanded != nil { toggle() } }
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
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
        triage.aggregateAgentState(in: container, session: session)
    }

    fileprivate func agentBreakdown(in container: ContainerID) -> [AgentState: Int] {
        triage.agentStateBreakdown(in: container, session: session)
    }

}

/// `+` next to the PROJECTS section header. Shows a `Menu` so the
/// user can pick a recent project or open a folder picker — bundling
/// both behind one affordance preserves the Recent-Projects shortcut
/// that lived in the old chrome `+` menu.
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
    }
}

/// Filled circle badge with a `+` glyph — used as the visual for the
/// GROUPS / PROJECTS section-header add affordance. Reads as a
/// solid, always-on button (vs the chevron's text-weight glyph)
/// without resorting to a full Chrome capsule shape.
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
