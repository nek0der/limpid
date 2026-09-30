// UnreadCountBadge.swift
// Limpid — the orange count of unread notifications.
//
// The toolbar bell and the notification history header both show the
// same number, and each drew its own badge: 9pt bold in a 14pt capsule
// on the bell, 10.5pt medium in an 18pt one in the header. They now
// share the bell's, the one users see first and the one sized to sit
// on an icon.

import SwiftUI

struct UnreadCountBadge: View {
    let count: Int

    var body: some View {
        // Nothing at zero rather than a "0": an empty bell already says
        // there is nothing to read.
        if count > 0 {
            Text(UnreadBadge.text(for: count))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LimpidColor.onAccent)
                // A circle for one or two digits, widening only for "99+".
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Capsule().fill(LimpidColor.notificationBell))
        }
    }
}
