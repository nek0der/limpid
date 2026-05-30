// NotificationHistoryView.swift
// Limpid — popover panel showing every notification Limpid has ever
// fired. Reachable from either bell button (sidebar / chrome capsule)
// and from `⌘⇧N`.

import SwiftUI

struct NotificationHistoryView: View {
    @Environment(NotificationHistoryStore.self) private var store
    @Environment(NotificationHistoryPresentation.self) private var presentation
    /// Returns true if the pane id still resolves to a live SurfaceView
    /// in some open tab — controls whether a history row is clickable
    /// vs. greyed out as a closed source.
    let isPaneAlive: (UUID) -> Bool
    let onJumpToPane: (UUID) -> Void

    var body: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            if store.entries.isEmpty {
                emptyState
            } else {
                list
                    // Shorten the scroller track at the top + bottom so
                    // it doesn't run into the popover's rounded corners.
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 360, height: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Notifications")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            if store.unreadCount > 0 {
                // Perfect circle for 1-2 digit counts; the
                // notification bell color (orange) keeps the popover
                // visually in lockstep with the chrome badge.
                Text("\(min(store.unreadCount, 99))")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(LimpidColor.notificationBell))
            }
            Spacer()
            Button("Mark All as Read") { store.markAllRead() }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.unreadCount == 0)
            Button {
                store.clearAll()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Clear All")
            .disabled(store.entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No notifications yet")
                .font(LimpidFont.bodySecondary)
                .foregroundStyle(.secondary)
            Text("Long-running commands and OSC 9 / 777 alerts land here.")
                .font(LimpidFont.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.entries) { entry in
                    let alive = entry.paneID.map(isPaneAlive) ?? false
                    NotificationHistoryRow(
                        entry: entry,
                        isSourceAlive: alive,
                        onTap: {
                            store.markRead(entry.id)
                            if alive, let paneID = entry.paneID {
                                onJumpToPane(paneID)
                                presentation.isPresented = false
                            }
                        },
                        onDelete: { store.delete(entry.id) }
                    )
                    Divider().opacity(0.15).padding(.leading, 14)
                }
            }
        }
    }
}

private struct NotificationHistoryRow: View {
    let entry: NotificationEntry
    /// False when the originating pane is no longer open. Row goes
    /// dim, the hover hint shows "Source closed", and clicks just mark
    /// the entry read instead of trying to jump anywhere.
    let isSourceAlive: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                kindIcon
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        // The leading `kindIcon` (filled / outlined
                        // circle) already conveys read state, so the
                        // small accent dot that used to sit next to
                        // the title has been removed — keeping two
                        // unread markers in the same row was visual
                        // duplication.
                        Spacer(minLength: 4)
                        // Timestamp and the per-row delete X share the
                        // same slot — toggling between them with `if`
                        // shifts the row width on hover, so we stack
                        // both in a fixed-width ZStack and crossfade
                        // via opacity.
                        ZStack(alignment: .trailing) {
                            Text(timeLabel)
                                .font(.system(size: 10.5, design: .rounded))
                                .foregroundStyle(.secondary)
                                .opacity(isHovering ? 0 : 1)
                            Button(action: onDelete) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss")
                            .opacity(isHovering ? 1 : 0)
                            .allowsHitTesting(isHovering)
                        }
                        .frame(width: 28, alignment: .trailing)
                    }
                    Text(entry.body)
                        .font(LimpidFont.bodySecondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    metaRow
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(rowBackground)
            .opacity(isSourceAlive ? 1.0 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isSourceAlive ? "" : "Source pane was closed")
    }

    /// Compact chip stack beneath the body — tab title on its own
    /// line, container on the next. Each chip self-hides when its
    /// data isn't available, so simpler notifications still render
    /// compactly. Stacking vertically (instead of side-by-side) keeps
    /// long tab titles and container paths readable without forcing
    /// the popover row to wrap or truncate mid-label.
    @ViewBuilder
    private var metaRow: some View {
        let chips = buildMetaChips()
        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    metaChip(chip)
                }
            }
        }
    }

    private struct MetaChip {
        let icon: String
        let text: String
        let color: Color
    }

    private func buildMetaChips() -> [MetaChip] {
        var chips: [MetaChip] = []
        if let tab = entry.tabTitleSnapshot,
           !tab.isEmpty,
           tab != entry.title
        {
            chips.append(MetaChip(icon: "macwindow", text: tab, color: LimpidColor.tertiaryText))
        }
        if let container = entry.containerLabel, !container.isEmpty {
            chips.append(MetaChip(icon: "folder", text: container, color: LimpidColor.tertiaryText))
        }
        // Exit code is already conveyed by the kind icon (red ✗), the
        // row's error background tint, AND the "(exit N)" suffix the
        // event coordinator appends to the body. Adding a chip too
        // would be the 4th channel for the same signal — skip.
        return chips
    }

    private func metaChip(_ chip: MetaChip) -> some View {
        HStack(spacing: 4) {
            Image(systemName: chip.icon)
                .font(.system(size: 9, weight: .medium))
            Text(chip.text)
                .font(LimpidFont.caption)
                // Long worktree paths or tab titles otherwise wrap
                // to a second line; we want each chip on exactly one
                // line, with the tail of the path collapsing to "…"
                // instead of pushing the row taller.
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(chip.color)
    }

    /// Row background — hover fill only. The red kind icon already
    /// conveys "failed", no need to also tint the whole row.
    private var rowBackground: Color {
        if isHovering, isSourceAlive { return LimpidColor.rowHoverFill }
        return .clear
    }

    /// Leading read-state indicator — solid orange `circle.fill` for
    /// unread, hollow `circle` outline for read. Same SF Symbol slot
    /// in either state so the title's leading edge stays put when an
    /// entry is acknowledged. The popover header already says
    /// "Notifications", so dropping the per-row bell that used to
    /// live here removes redundant signal without losing information —
    /// `commandFinished` exit-code status is still conveyed by the
    /// `(exit N)` suffix the coordinator appends to the body.
    private var kindIcon: some View {
        let name = entry.isRead ? "circle" : "circle.fill"
        let color = entry.isRead
            ? LimpidColor.tertiaryText
            : LimpidColor.notificationBell
        return Image(systemName: name)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .accessibilityLabel(entry.isRead ? "Read" : "Unread")
    }

    private var timeLabel: String {
        let now = Date()
        let delta = now.timeIntervalSince(entry.timestamp)
        if delta < 60 { return "now" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86400 { return "\(Int(delta / 3600))h" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: entry.timestamp)
    }
}
