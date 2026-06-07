// NotificationBell.swift
// Limpid — single shared indicator used wherever the UI surfaces an
// unread notification (TabRow trailing, ContainerRow trailing,
// the toolbar bell button). One component keeps the size / color /
// animation consistent across every appearance.

import SwiftUI

struct NotificationBell: View {
    let isUnread: Bool
    var isRinging: Bool = false
    var size: CGFloat = 11

    /// `true` reserves a fixed 16×16 slot whether or not the bell is
    /// currently drawn — sidebar trailing accessories (ContainerRow,
    /// TabRow) rely on uniform-width trailing items so the state
    /// icon, bell, and chevron all sit on the same x-axis.
    /// `false` keeps the historical 0-width-when-empty behavior for
    /// toolbar / settings call sites that don't share a grid.
    var reservesSlot: Bool = false

    var body: some View {
        Group {
            if isUnread {
                Image(systemName: "bell.fill")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(LimpidColor.notificationBell)
                    .symbolEffect(.bounce, value: isRinging)
                    .accessibilityLabel("Unread notifications")
            }
        }
        .frame(
            width: reservesSlot ? 16 : nil,
            height: reservesSlot ? 16 : nil
        )
    }
}
