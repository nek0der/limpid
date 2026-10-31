// NotificationDeliveryStatusLoading.swift
// Weir — whether banners reach the person, read for the notification history, and the way to fix it.

import AppKit
import SwiftUI
import WeirDomain

/// The Notifications pane of System Settings, which the history's notice and
/// its ⋯ open. macOS has no documented link to one app's row in it, so it
/// opens the pane.
enum NotificationSettingsPane {
    static let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
}

extension View {
    /// Reads whether a banner will reach the person into `status` when the
    /// view appears and again when Weir comes back to the front, which is
    /// when a change made in System Settings would show. Put it on a view
    /// that is always there: one that appears only once `status` is known
    /// would never read it.
    func loadsNotificationDeliveryStatus(_ status: Binding<NotificationDeliveryStatus?>) -> some View {
        modifier(NotificationDeliveryStatusLoader(status: status))
    }
}

private struct NotificationDeliveryStatusLoader: ViewModifier {
    @Environment(\.notificationManager) private var notificationManager
    @Binding var status: NotificationDeliveryStatus?

    func body(content: Content) -> some View {
        content
            .task { await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refresh() }
            }
    }

    private func refresh() async {
        guard let notificationManager else { return }
        status = await notificationManager.deliveryStatus()
    }
}
