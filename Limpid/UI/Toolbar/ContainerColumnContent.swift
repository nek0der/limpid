// ContainerColumnContent.swift
// Limpid — the *whole* container slab interior: a 52pt top toolbar row that
// shares space with the traffic-light buttons (which AppKit renders
// over the slab's top-left corner), followed by the scrollable
// container list. Lives inside the floating Liquid Glass slab so the
// toolbar buttons read as "part of the sidebar" instead of a separate
// toolbar — matches the "traffic lights live inside the sidebar" intent.

import SwiftUI

struct ContainerColumnContent: View {
    @Environment(WindowSession.self) private var session
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(\.surfaceRegistry) private var registry

    var body: some View {
        @Bindable var historyPresentation = historyPresentation
        @Bindable var session = session
        VStack(spacing: 0) {
            ToolbarRow(position: .container) {
                HStack(spacing: 0) {
                    Spacer().frame(width: LimpidLayout.trafficLightWidth)
                    Spacer()
                    // Standalone buttons (no surrounding capsule) — the
                    // slab itself provides the material backdrop.
                    HStack(spacing: 2) {
                        // Add affordance moved next to GROUPS /
                        // PROJECTS section headers — see
                        // `ContainerSlabView.sectionHeader`. The
                        // toolbar bar now only holds notification +
                        // sidebar-toggle so it doesn't compete with
                        // section-scoped affordances.
                        ToolbarBellButton()
                        ToolbarCapsuleButton(systemImage: "sidebar.left", help: "Hide Sidebar (⌘1)") {
                            withAnimation(LimpidMotion.sidebarToggle) {
                                session.sidebarHidden = true
                            }
                        }
                    }
                }
                .padding(.trailing, 12)
            }
            ContainerSlabView()
        }
    }
}

/// Notification bell — extracted from ToolbarTerminalColumnSegment so it can live
/// inside the container slab next to the add menu (per the "traffic lights →
/// add → bell → sidebar" arrangement).
struct ToolbarBellButton: View {
    @Environment(WindowSession.self) private var session
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.limpidAccent) private var accent

    var body: some View {
        @Bindable var historyPresentation = historyPresentation
        ToolbarCapsuleButton(
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

/// Capsule shown when the sidebar is hidden — same shape as the container column
/// toolbar capsule above so the two stay visually consistent.
struct FloatingHiddenToolbar: View {
    @Environment(WindowSession.self) private var session

    var body: some View {
        @Bindable var session = session
        ToolbarActionCapsule {
            // No `+` here — when the sidebar is hidden the section
            // headers (where add lives now) aren't visible. Users
            // reveal the sidebar first (⌘1) to add a Group/Project.
            ToolbarBellButton()
            ToolbarCapsuleDivider()
            ToolbarCapsuleButton(systemImage: "sidebar.left", help: "Show Sidebar (⌘1)") {
                withAnimation(LimpidMotion.sidebarToggle) {
                    session.sidebarHidden = false
                }
            }
        }
    }
}
