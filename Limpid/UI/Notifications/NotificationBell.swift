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

    var body: some View {
        if isUnread {
            Image(systemName: "bell.fill")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(LimpidColor.notificationBell)
                .symbolEffect(.bounce, value: isRinging)
                .accessibilityLabel("Unread notifications")
        }
    }
}
