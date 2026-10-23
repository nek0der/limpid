// NotificationDeliveryStatus.swift
// Limpid — whether a notification would reach the person now: macOS's permission and Focus.

import Foundation

/// What decides whether a banner reaches the person, shown at the foot of
/// the notification history so they can check before stepping away.
struct NotificationDeliveryStatus: Equatable, Sendable {
    /// Limpid's notification permission in macOS.
    enum Permission: Equatable, Sendable {
        /// Allowed, with banners or alerts.
        case allowed
        /// Allowed, but set to show nothing on screen (the alert style is
        /// None, or macOS's quiet trial, which only fills Notification
        /// Center): a notification arrives, but no banner tells the person.
        case allowedWithoutBanners
        case denied
        /// macOS has not asked yet.
        case notAsked
    }

    /// Whether a Focus is on.
    enum Focus: Equatable, Sendable {
        case on
        case off
        /// Limpid cannot read it. Reading Focus takes the Communication
        /// Notifications entitlement and the person's own consent, and
        /// Limpid has neither, so this is what it shows today.
        case unknown
    }

    var permission: Permission
    var focus: Focus = .unknown
}
