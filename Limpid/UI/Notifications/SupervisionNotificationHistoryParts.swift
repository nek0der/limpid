// SupervisionNotificationHistoryParts.swift
// Limpid — the notification history's heading, ⋯ menu, notice, and states as the supervision window draws them.

import SwiftUI

/// The panel's name, then what acts on the whole list: Mark All as Read
/// while anything is unread, and ⋯ (`SupervisionHistoryMoreMenu`). The
/// name stands alone, as every other panel's does. Mark All as Read is a
/// ghost button (`SupervisionSecondaryButtonStyle`'s `.ghost`): an action
/// on the list, so not a capsule that reads as one more filter, and not a
/// link, whose blue marks only unread and unviewed. It sits here
/// rather than in the filters' line, which in Japanese has no room for a
/// fifth.
struct SupervisionHistoryHeading: View {
    let canMarkAllRead: Bool
    let canClear: Bool
    let onMarkAllRead: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: LimpidLayout.Supervision.spaceS) {
            Text("Notification History")
                .font(.supervision(.label, weight: .bold))
                .foregroundStyle(SupervisionTokens.text.color)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: LimpidLayout.Supervision.spaceS)
            if canMarkAllRead {
                Button("Mark All as Read", action: onMarkAllRead)
                    .buttonStyle(.supervisionSecondary(tone: .ghost))
                    .accessibilityLabel(Text("Mark All as Read"))
            }
            SupervisionHistoryMoreMenu(canClear: canClear, onClear: onClear)
        }
        // The line keeps its height when Mark All as Read goes, so the rows
        // below do not move.
        .frame(height: LimpidLayout.Supervision.notificationHeadingHeight)
    }
}

/// The heading's ⋯: what is used now and then, kept off the panel so the
/// rows have it: Test Notification and Notification Settings…, then
/// Clear All…, which asks first.
struct SupervisionHistoryMoreMenu: View {
    @Environment(\.notificationManager) private var notificationManager
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.openURL) private var openURL
    let canClear: Bool
    let onClear: () -> Void

    var body: some View {
        Menu {
            Button("Test Notification") {
                notificationManager?.sendTestNotification()
                toastCenter.showInFrontWindow(ToastItem(.testNotificationSent))
            }
            .disabled(notificationManager == nil)
            Button("Notification Settings…") {
                guard let url = NotificationSettingsPane.url else { return }
                openURL(url)
            }
            Divider()
            Button("Clear All…", role: .destructive, action: onClear)
                .disabled(!canClear)
        } label: {
            Image(systemName: "ellipsis")
                .font(.supervision(.label, weight: .medium))
                .foregroundStyle(SupervisionTokens.muted.color)
                // The whole square takes the click, not only the dots.
                .frame(
                    width: LimpidLayout.Supervision.notificationHeadingHeight,
                    height: LimpidLayout.Supervision.notificationHeadingHeight
                )
                .contentShape(Rectangle())
        }
        // A plain button draws the label as SwiftUI lays it out, so the ⋯
        // keeps its muted color and its whole square takes the click; a
        // borderless menu draws it in AppKit, in the accent, dots only.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("More Actions"))
        .accessibilityLabel(Text("More Actions"))
    }
}

/// Said in place of the footer only while a banner may not reach the
/// person (`NotificationDeliveryStatusText.notice`), with the way to fix
/// it. The panel reads `status` (`loadsNotificationDeliveryStatus`), as
/// this view is not there until it is known.
struct SupervisionHistoryDeliveryNotice: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    let status: NotificationDeliveryStatus?

    var body: some View {
        if let notice = status.flatMap({ NotificationDeliveryStatusText.notice($0, locale: locale) }) {
            // One line while the notice and its button fit side by side; a
            // longer notice, or a narrower panel, puts the button under it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: LimpidLayout.Supervision.spaceS) {
                    icon
                    Text(verbatim: notice)
                        .font(.supervision(.row))
                        .foregroundStyle(SupervisionTokens.text.color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: LimpidLayout.Supervision.spaceS)
                    settingsButton
                }
                HStack(alignment: .firstTextBaseline, spacing: LimpidLayout.Supervision.spaceS) {
                    icon
                    VStack(alignment: .leading, spacing: LimpidLayout.Supervision.spaceXS) {
                        Text(verbatim: notice)
                            .font(.supervision(.row))
                            .foregroundStyle(SupervisionTokens.text.color)
                            .fixedSize(horizontal: false, vertical: true)
                        settingsButton
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(LimpidLayout.Supervision.notificationNoticeInsets)
            .background(
                RoundedRectangle(cornerRadius: LimpidLayout.Supervision.notificationRowCornerRadius, style: .continuous)
                    .fill(SupervisionTokens.waitingFill.color)
            )
            .padding(.top, LimpidLayout.Supervision.spaceS)
        }
    }

    private var icon: some View {
        Image(systemName: "bell.slash")
            .font(.supervision(.caption, weight: .medium))
            .foregroundStyle(SupervisionTokens.waiting.color)
            .accessibilityHidden(true)
    }

    /// Edged, as a banner's way to fix it is, not a link: blue marks only
    /// unread and unviewed.
    private var settingsButton: some View {
        Button("Notification Settings…") {
            guard let url = NotificationSettingsPane.url else { return }
            openURL(url)
        }
        .buttonStyle(.supervisionSecondary(size: .compact, tone: .onStateFill))
    }
}

/// "Today", "Yesterday", "Earlier", in the muted token.
struct SupervisionHistoryDayHeading: View {
    let title: LocalizedStringResource
    /// The first day, right under the filters rather than after rows.
    let isFirst: Bool

    var body: some View {
        Text(title)
            .font(.supervision(.caption, weight: .semibold))
            .foregroundStyle(SupervisionTokens.muted.color)
            .padding(LimpidLayout.Supervision.notificationDayInsets(isFirst: isFirst))
            .accessibilityAddTraits(.isHeader)
    }
}

/// The in-panel confirmation before every notification goes. Clear All is
/// the destructive button every supervision surface shares: edged, its
/// title in the stop's red, never filled.
struct SupervisionHistoryClearConfirmation: View {
    let onCancel: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: LimpidLayout.Supervision.spaceSnug) {
            Image(systemName: "trash")
                .font(.supervision(.title))
                .foregroundStyle(SupervisionTokens.muted.color)
                .accessibilityHidden(true)
            Text("Clear all notifications?")
                .font(.supervision(.label, weight: .bold))
                .foregroundStyle(SupervisionTokens.text.color)
            Text("This can’t be undone.")
                .font(.supervision(.row))
                .foregroundStyle(SupervisionTokens.muted.color)
            HStack(spacing: LimpidLayout.Supervision.spaceS) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.supervisionSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Clear All", role: .destructive, action: onClear)
                    .buttonStyle(.supervisionSecondary(tone: .destructive))
            }
            .padding(.top, LimpidLayout.Supervision.spaceSnug)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}
