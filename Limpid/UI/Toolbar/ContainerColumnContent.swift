// ContainerColumnContent.swift
// Limpid — the container sidebar interior: titlebar clearance followed
// by the scrollable container list. The interactive titlebar controls
// live in `ThreePaneLayout` so the sidebar can move beneath them.

import SwiftUI

struct ContainerColumnContent: View {
    /// The sidebar stays mounted offscreen. Only visible content may present
    /// sheets or alerts.
    let isPresentationEnabled: Bool
    @Binding var creatingWorktreeFor: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // The titlebar controls live in `ThreePaneLayout` so they remain
            // fixed while this surface moves beneath them.
            ToolbarRow { EmptyView() }
            ContainerSlabView(
                isPresentationEnabled: isPresentationEnabled,
                creatingWorktreeFor: $creatingWorktreeFor
            )
        }
    }
}

/// Notification bell shared by the sidebar and hidden-sidebar controls.
struct ToolbarBellButton: View {
    @Environment(WindowSession.self) private var session
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.limpidAccent) private var accent

    var body: some View {
        @Bindable var historyPresentation = historyPresentation
        ToolbarIconButton(
            systemImage: session.windowHasUnread ? "bell.fill" : "bell",
            help: "Notification History"
        ) {
            historyPresentation.isPresented.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if session.windowHasUnread {
                Text(badgeText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(LimpidColor.notificationBell))
                    .offset(x: -4, y: 2)
                    .symbolEffect(.bounce, value: session.windowIsRinging)
                    .accessibilityLabel("\(session.windowUnreadCount) unread")
            }
        }
        .popover(isPresented: $historyPresentation.isPresented, arrowEdge: .bottom) {
            NotificationHistoryView(
                isPaneAlive: { paneID in
                    session.tab(containing: paneID) != nil
                },
                onJumpToPane: { paneID in
                    jumpToPane(paneID, session: session, registry: registry)
                }
            )
            .limpidAccentPropagated(accent)
        }
    }

    private var badgeText: String {
        let n = session.windowUnreadCount
        return n > 99 ? "99+" : "\(n)"
    }
}

/// Sidebar controls fixed beside the traffic lights while the slab moves below.
struct FloatingSidebarToolbar: View {
    let isSidebarPresented: Bool
    @Environment(WindowSession.self) private var session

    var body: some View {
        HStack(spacing: 4) {
            ToolbarBellButton()
            ToolbarIconButton(
                systemImage: "sidebar.left",
                help: isSidebarPresented ? "Hide Sidebar (⌘1)" : "Show Sidebar (⌘1)"
            ) {
                NotificationCenter.default.post(
                    name: .limpidToggleSidebarPresentation,
                    object: session
                )
            }
        }
    }
}
