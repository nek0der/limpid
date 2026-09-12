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
///
/// The badge counts unread *history* rows, not per-pane unread. The
/// two used to diverge: agent turns are recorded in history but never
/// bump a pane's unread count, so the panel could open on a dozen
/// unread rows under a bell that showed nothing. History is the
/// number the panel header and the Dock badge display too, so the
/// three now move together.
struct ToolbarBellButton: View {
    @Environment(WindowSession.self) private var session
    @Environment(NotificationHistoryStore.self) private var historyStore
    @Environment(NotificationHistoryPresentation.self) private var historyPresentation
    @State private var isHovering = false

    var body: some View {
        let unread = historyStore.unreadCount
        Button {
            toggleNotificationHistory(historyPresentation, session: session)
        } label: {
            ToolbarIconLabel(
                systemImage: unread > 0 ? "bell.fill" : "bell",
                isEnabled: true,
                isHovering: isHovering
            )
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    Text(badgeText(unread))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(LimpidColor.notificationBell))
                        .offset(x: -4, y: 2)
                        .symbolEffect(.bounce, value: session.windowIsRinging)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Notification History")
        .accessibilityLabel(Text("Notification History"))
        .accessibilityValue(Text("\(unread) unread"))
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            historyPresentation.anchorFrame = frame
        }
    }

    private func badgeText(_ n: Int) -> String {
        n > 99 ? "99+" : "\(n)"
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
