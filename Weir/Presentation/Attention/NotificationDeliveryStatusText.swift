// NotificationDeliveryStatusText.swift
// Weir — the notification history's notice when a banner may not reach the person.

import Foundation

/// The notice the notification history shows when a banner may not reach
/// the person.
enum NotificationDeliveryStatusText {
    /// The history says nothing while a banner will reach the person, and
    /// one sentence when it may not: a status line that reads
    /// "Allowed" every time teaches the eye to skip it,
    /// which is the one time it should be read. A Focus Weir cannot read
    /// says nothing either, as there is nothing the person could act on.
    static func notice(_ status: NotificationDeliveryStatus, locale: Locale) -> String? {
        let resource: LocalizedStringResource? = switch (status.permission, status.focus) {
        case (.denied, _): LocalizedStringResource(
                "macOS notifications are off.",
                comment: "Notification history: Weir's notification permission is turned off in macOS"
            )
        case (.notAsked, _): LocalizedStringResource(
                "macOS hasn’t asked yet whether to allow notifications.",
                comment: "Notification history: macOS has not asked for Weir's notification permission"
            )
        case (.allowedWithoutBanners, _): LocalizedStringResource(
                "macOS shows no banners.",
                comment: "Notification history: notifications are allowed, but set to show no banner or alert"
            )
        case (.allowed, .on): LocalizedStringResource(
                "A Focus is on, so banners may not show.",
                comment: "Notification history: a Focus is on"
            )
        case (.allowed, .off), (.allowed, .unknown): nil
        }
        return resource?.resolved(in: locale)
    }
}
