// RailBadgeTests.swift
// Limpid — the history's bell shows a dot, the changes panel's icon a count.

import Foundation
import Testing
@testable import Limpid

struct RailBadgeTests {
    private let english = Locale(identifier: "en")
    private let japanese = Locale(identifier: "ja")

    @Test func historyBell_withNothingUnread_carriesNoMarkAndSaysOnlyItsName() {
        #expect(NotificationHistoryRailText.badge(unread: 0) == nil)
        #expect(NotificationHistoryRailText.unreadCount(0, locale: english) == nil)
        #expect(NotificationHistoryRailText.help(shortcut: "⇧⌘N", unread: 0, locale: english) == "Notification History (⇧⌘N)")
    }

    @Test func historyBell_withUnread_showsADot_andTheCountOnlyInWords() {
        #expect(NotificationHistoryRailText.badge(unread: 1) == .dot)
        #expect(NotificationHistoryRailText.badge(unread: 27) == .dot)

        #expect(NotificationHistoryRailText.unreadCount(27, locale: english) == "27 unread")
        #expect(NotificationHistoryRailText.unreadCount(27, locale: japanese) == "未読 27")
        #expect(NotificationHistoryRailText.help(shortcut: "⇧⌘N", unread: 27, locale: english) == "Notification History (⇧⌘N) · 27 unread")
        #expect(NotificationHistoryRailText.help(shortcut: nil, unread: 27, locale: japanese) == "通知履歴 · 未読 27")
    }

    @Test func changesIcon_keepsItsCount_andNothingAtZero() {
        #expect(RailBadge.counting(0) == nil)
        #expect(RailBadge.counting(3) == .count(3))
        #expect(RailBadge.counting(120) == .count(120))
        #expect(RailBadge.text(for: 120) == "99+")
    }
}
