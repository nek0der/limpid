// ContainerColumnContent.swift
// Limpid — the *whole* container sidebar interior: a 52pt top toolbar
// row that shares space with the traffic-light buttons (which AppKit
// renders over the sidebar's top-left corner), followed by the
// scrollable container list. Lives inside the flush Liquid Glass
// sidebar so the toolbar buttons read as "part of the sidebar" instead
// of a separate toolbar — matches the "traffic lights live inside the
// sidebar" intent.

import SwiftUI

struct ContainerColumnContent: View {
    @Environment(WindowSession.self) private var session
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(\.surfaceRegistry) private var registry

    var body: some View {
        @Bindable var historyPresentation = historyPresentation
        @Bindable var session = session
        VStack(spacing: 0) {
            ToolbarRow {
                HStack(spacing: 0) {
                    Spacer().frame(width: LimpidLayout.trafficLightWidth)
                    HStack(spacing: 4) {
                        ToolbarBellButton()
                        ToolbarIconButton(systemImage: "sidebar.left", help: "Hide Sidebar (⌘1)") {
                            NotificationCenter.default.post(
                                name: .limpidToggleSidebarPresentation,
                                object: session
                            )
                        }
                    }
                    .padding(.leading, 10)
                    Spacer()
                }
            }
            ContainerSlabView()
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

/// Sidebar controls shown beside the traffic lights while the sidebar is hidden.
struct FloatingHiddenToolbar: View {
    @Environment(WindowSession.self) private var session

    var body: some View {
        @Bindable var session = session
        HStack(spacing: 4) {
            ToolbarBellButton()
            ToolbarIconButton(systemImage: "sidebar.left", help: "Show Sidebar (⌘1)") {
                NotificationCenter.default.post(
                    name: .limpidToggleSidebarPresentation,
                    object: session
                )
            }
        }
    }
}
