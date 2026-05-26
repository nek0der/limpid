// NotificationBell.swift
// Limpid — single shared indicator used wherever the UI surfaces an
// unread notification (L2 TabRow trailing, L1 ContainerRow trailing,
// the chrome bell button). One component keeps the size / colour /
// animation consistent across every appearance.

import SwiftUI

struct NotificationBell: View {
    let isUnread: Bool
    var isRinging: Bool = false
    var size: CGFloat = 11

    /// `true` reserves a fixed 16×16 slot whether or not the bell is
    /// currently drawn — sidebar trailing accessories (L1 ContainerRow,
    /// L2 TabRow) rely on uniform-width trailing items so the state
    /// icon, bell, and chevron all sit on the same x-axis.
    /// `false` keeps the historical 0-width-when-empty behaviour for
    /// chrome / settings call sites that don't share a grid.
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
