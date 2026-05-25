// TabRow.swift
// Limpid — single row in the L2 tab list. Flat list (no indent for
// hierarchy — that lives in L1). Shows an unread dot, the title, and
// hover/active close button. Inline rename on double-click.

import SwiftUI

struct TabRow: View {
    @Environment(WindowSession.self) private var session
    @Environment(LimpidDragState.self) private var dragState
    let tab: Tab
    let onActivate: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onUnzoom: () -> Void

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

    var body: some View {
        HStack(spacing: 8) {
            InlineRenameField(
                text: $draft,
                isEditing: $isEditing,
                font: .system(size: 13, weight: .medium, design: .rounded),
                foregroundColor: isActive ? .primary : .secondary,
                onCommit: { value in commitRename(value) },
                onCancel: { cancelRename() }
            )
            .layoutPriority(1)
            .onTapGesture(count: 2) {
                if !isEditing { beginRename() }
            }
            .onChange(of: tab.displayTitle) { _, new in
                if !isEditing { draft = new }
            }
            .onAppear {
                if !isEditing { draft = tab.displayTitle }
            }
            Spacer(minLength: 4)
            NotificationBell(isUnread: hasUnread, isRinging: isRinging)
            if isZoomed {
                // Always-visible state indicator with a tap target so the
                // user can leave zoom mode without remembering ⌘⇧Return.
                // Sits between the bell (passive status) and the close
                // button (action) since it's an actionable affordance.
                Button(action: onUnzoom) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Unzoom Pane")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovering ? 1 : 0)
            .allowsHitTesting(isActive || isHovering)
        }
        .padding(.leading, 28)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectablePillBackground(isActive: isActive, isHovering: isHovering)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            if isEditing { return }
            onActivate()
        }
        .contextMenu {
            Button {
                beginRename()
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive, action: onClose) {
                Label("Close", systemImage: "xmark")
            }
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
        onRename(trimmed)
        isEditing = false
    }

    private func cancelRename() {
        draft = tab.displayTitle
        isEditing = false
    }
}

// MARK: - TabsListView

/// The L2 body — flat list of TabRow for the active container, with
/// an empty-state when zero tabs exist. L2 used to be a mode picker
/// (Tabs / Log / Diff / Stash); after the mode switcher came out only
/// the tabs list survived, so this view is now the entire L2 body.
struct TabsListView: View {
    @Environment(WindowSession.self) private var session
    @Environment(\.surfaceRegistry) private var registry
    let container: ContainerID

    var body: some View {
        let tabs = session.tabs(in: container)
        if tabs.isEmpty {
            L2EmptyState(container: container)
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
                                SessionActions.closeTab(session, registry: registry, tabID: tab.id)
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
                        .insertionLine(beforeTabID: tab.id, container: container, session: session)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func renameTab(_ tabID: UUID, to newName: String) {
        session.update(tabID) { t in
            t.titleOverride = newName.isEmpty ? nil : newName
        }
    }
}

// MARK: - In-list reorder helper (uses the shared insertion-line modifier)

private extension View {
    /// Treat this tab row as a reorder target. The `isNoOp` closure
    /// hides the indicator for "drop where you already are" cases —
    /// dropping ON yourself, just before the next tab (= current
    /// position), or just after the previous tab (= current position).
    func insertionLine(
        beforeTabID: UUID,
        container: ContainerID,
        session: WindowSession
    ) -> some View {
        reorderableDropTarget(
            targetID: "tab-\(beforeTabID)",
            acceptedPrefixes: ["tab:"],
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
            }
        ) { _, sourceID, position in
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
    }
}

// MARK: - Empty state

private struct L2EmptyState: View {
    @Environment(WindowSession.self) private var session
    let container: ContainerID

    var body: some View {
        VStack(spacing: 12) {
            Text("No sessions")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(LimpidColor.tertiaryText)
            Button {
                _ = session.openTab(container: container)
            } label: {
                Label("New Session", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(
                Capsule().fill(LimpidColor.rowHoverFill)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
