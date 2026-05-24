// L1SlabContent.swift
// Limpid — the *whole* L1 slab interior: a 52pt top chrome row that
// shares space with the traffic-light buttons (which AppKit renders
// over the slab's top-left corner), followed by the scrollable
// container list. Lives inside the floating Liquid Glass slab so the
// chrome buttons read as "part of the sidebar" instead of a separate
// toolbar — matches the "traffic lights live inside the sidebar" intent.

import SwiftUI

struct L1SlabContent: View {
    @Environment(WindowSession.self) private var session
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(\.surfaceRegistry) private var registry

    var body: some View {
        @Bindable var historyPresentation = historyPresentation
        @Bindable var session = session
        VStack(spacing: 0) {
            ChromeRow(position: .l1) {
                HStack(spacing: 0) {
                    Spacer().frame(width: LimpidLayout.trafficLightWidth)
                    Spacer()
                    // Standalone buttons (no surrounding capsule) — the
                    // slab itself provides the material backdrop.
                    HStack(spacing: 2) {
                        // Add affordance moved next to GROUPS /
                        // PROJECTS section headers — see
                        // `ContainerSlabView.sectionHeader`. The
                        // chrome bar now only holds notification +
                        // sidebar-toggle so it doesn't compete with
                        // section-scoped affordances.
                        ChromeBellButton()
                        ChromeCapsuleButton(systemImage: "sidebar.left", help: "Hide Sidebar (⌘1)") {
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

/// Notification bell — extracted from ChromeL3Segment so it can live
/// inside the L1 slab next to the add menu (per the "traffic lights →
/// add → bell → sidebar" arrangement).
struct ChromeBellButton: View {
    @Environment(WindowSession.self) private var session
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @Environment(\.surfaceRegistry) private var registry

    var body: some View {
        @Bindable var historyPresentation = historyPresentation
        ChromeCapsuleButton(
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
        }
    }

    private var badgeText: String {
        let n = session.windowUnreadCount
        return n > 99 ? "99+" : "\(n)"
    }
}

/// Capsule shown when the sidebar is hidden — same shape as the L1
/// chrome capsule above so the two stay visually consistent.
struct FloatingHiddenChrome: View {
    @Environment(WindowSession.self) private var session

    var body: some View {
        @Bindable var session = session
        ChromeActionCapsule {
            // No `+` here — when the sidebar is hidden the section
            // headers (where add lives now) aren't visible. Users
            // reveal the sidebar first (⌘1) to add a Group/Project.
            ChromeBellButton()
            ChromeCapsuleDivider()
            ChromeCapsuleButton(systemImage: "sidebar.left", help: "Show Sidebar (⌘1)") {
                withAnimation(LimpidMotion.sidebarToggle) {
                    session.sidebarHidden = false
                }
            }
        }
    }
}
