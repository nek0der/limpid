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

    /// `true` reserves one `LimpidLayout.containerColumnTrailingSlot`
    /// whether or not the bell is drawn, so a row's trailing group
    /// keeps its width as the accessories around the bell come and go.
    /// On `ContainerRow` it is the only slot held unconditionally, and
    /// therefore what anchors that group's right edge; `TabRow` holds
    /// further slots of its own.
    /// `false` keeps the 0-width-when-empty behavior for toolbar and
    /// settings call sites that share no grid.
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
            width: reservesSlot ? LimpidLayout.containerColumnTrailingSlot : nil,
            height: reservesSlot ? LimpidLayout.containerColumnTrailingSlot : nil
        )
    }
}
