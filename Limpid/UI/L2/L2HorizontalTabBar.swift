// L2HorizontalTabBar.swift
// Limpid — horizontal tab strip shown above L3 when the user toggles
// the tab layout. Reuses the exact same `TabRow` the vertical L2 list
// renders, so rename, context menu, drag-reorder, bell, and agent
// badges all behave identically — only the axis differs. Tabs share
// the width evenly until they would shrink past a readable minimum, at
// which point the strip becomes horizontally scrollable and keeps the
// active tab centered.

import SwiftUI

struct L2HorizontalTabBar: View {
    @Environment(WindowSession.self) private var session
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.claudeSessionTracker) private var claudeSessionTracker
    @Environment(\.cwdEventTracker) private var cwdEventTracker
    @Environment(\.codexSessionTracker) private var codexSessionTracker
    let container: ContainerID

    /// Tab currently being inline-renamed; widened so the editor has
    /// room even when tabs are squeezed to their scrolling minimum.
    @State private var editingTabID: UUID?

    var body: some View {
        let tabs = session.tabs(in: container)
        GeometryReader { geo in
            // Width the strip needs to honour the per-tab minimum.
            // Subtract the strip's own horizontal padding so the test
            // matches what's actually available to the pills.
            let spacing = LimpidLayout.horizontalTabSpacing
            let usable = geo.size.width - 2 * LimpidLayout.horizontalTabStripInset
            let needed = CGFloat(tabs.count) * LimpidLayout.horizontalTabMinWidth
                + CGFloat(max(0, tabs.count - 1)) * spacing
            if needed <= usable {
                // Everything fits — share the width evenly.
                strip(tabs, pillWidth: nil)
                    .frame(width: geo.size.width, alignment: .leading)
            } else {
                // Too many tabs — pin each to the minimum and scroll,
                // keeping the active tab centered as selection moves.
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        strip(tabs, pillWidth: LimpidLayout.horizontalTabMinWidth)
                    }
                    .onChange(of: session.activeTabID) { _, id in
                        guard let id else { return }
                        withAnimation(LimpidMotion.paletteToggle) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onAppear {
                        if let id = session.activeTabID {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(height: LimpidLayout.horizontalTabBarHeight)
    }

    private func strip(_ tabs: [Tab], pillWidth: CGFloat?) -> some View {
        HStack(spacing: LimpidLayout.horizontalTabSpacing) {
            ForEach(tabs) { tab in
                TabRow(
                    tab: tab,
                    onActivate: { session.setActiveTab(tab.id) },
                    onClose: {
                        TabActions.closeTab(
                            session,
                            registry: registry,
                            tabID: tab.id,
                            source: .mouse,
                            claudeSessionTracker: claudeSessionTracker,
                            codexSessionTracker: codexSessionTracker,
                            cwdEventTracker: cwdEventTracker
                        )
                    },
                    onRename: { newName in renameTab(tab.id, to: newName) },
                    onUnzoom: {
                        session.setActiveTab(tab.id)
                        session.update(tab.id) { t in
                            t.zoomedLeafID = nil
                        }
                    },
                    onEditingChanged: { editing in
                        editingTabID = editing ? tab.id : (editingTabID == tab.id ? nil : editingTabID)
                    },
                    pillHorizontalPadding: 0
                )
                // Constrain each row to a column slot: a fixed minimum
                // when scrolling, otherwise an even share of the strip.
                // While renaming, a squeezed tab widens to give the
                // editor room.
                .frame(width: pillFrameWidth(tab, base: pillWidth))
                .frame(maxWidth: pillWidth == nil ? .infinity : nil)
                // Same drag-reorder as the vertical list, but the
                // before / after split runs along x instead of y.
                .tabReorderTarget(
                    beforeTabID: tab.id,
                    container: container,
                    session: session,
                    axis: .horizontal
                )
                .id(tab.id)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, LimpidLayout.horizontalTabStripInset)
        .animation(.easeOut(duration: LimpidLayout.renamePillDuration), value: editingTabID)
    }

    /// Per-tab width. Squeezed (scrolling) tabs widen to
    /// `tabPillMaxWidth` while being renamed; even-share tabs are
    /// already wide enough so they keep flexing.
    private func pillFrameWidth(_ tab: Tab, base: CGFloat?) -> CGFloat? {
        guard editingTabID == tab.id, let base else { return base }
        return max(base, LimpidLayout.tabPillMaxWidth)
    }

    private func renameTab(_ tabID: UUID, to newName: String) {
        session.update(tabID) { t in
            t.titleOverride = newName.isEmpty ? nil : newName
        }
    }
}
