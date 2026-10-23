// RailBadge.swift
// Limpid — what a rail icon carries: a count, a dot, or nothing.

import Foundation

/// The mark on a rail icon. A count where the number is what to act
/// on (the changes panel's turns waiting to be read); a dot where only
/// "something is there" is (unread history), so the bell's number is not
/// read as a count of what needs attention beside the title bar's
/// Needs Attention count. `nil` at a call site means no mark.
enum RailBadge: Equatable {
    /// A count above zero; build it with `counting(_:)`, which gives no
    /// mark at zero.
    case count(Int)
    case dot

    /// A count, or nothing at zero.
    static func counting(_ count: Int) -> RailBadge? {
        count > 0 ? .count(count) : nil
    }

    /// Past two digits a count says "99+", not a bare 99, which reads as
    /// an exact count.
    static func text(for count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }
}

/// The notification history's bell on the left rail: a dot while anything
/// is unread, and the count only in its tooltip and VoiceOver value.
enum NotificationHistoryRailText {
    static func badge(unread: Int) -> RailBadge? {
        unread > 0 ? .dot : nil
    }

    /// "Notification History (⇧⌘N) · 27 unread"; the name and key alone
    /// when nothing is unread.
    static func help(shortcut: String?, unread: Int, locale: Locale) -> String {
        let name = ShortcutHelpText.make(name: "Notification History", shortcut: shortcut, locale: locale)
        guard let count = unreadCount(unread, locale: locale) else { return name }
        return AgentStatusText.joined([name, count], locale: locale)
    }

    /// What VoiceOver reads after the bell's name; `nil` when nothing is
    /// unread, so it reads the name alone.
    static func unreadCount(_ unread: Int, locale: Locale) -> String? {
        guard unread > 0 else { return nil }
        return LocalizedStringResource("\(unread) unread").resolved(in: locale)
    }
}
