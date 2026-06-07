// LimpidNotificationManager.swift
// Limpid — `UNUserNotificationCenter` integration with rate limiting.
//
// Two design choices worth noting:
//   1. Rate limiting keys on the pane id, not the tab id, so split
//      panes inside the same tab can each fire independently.
//   2. We hand the underlying `UNNotificationRequest` userInfo a
//      pane id + a `requireFocus` flag so the `UNUserNotificationCenterDelegate`
//      can decide whether to present the alert while the app is in
//      the foreground (Ghostty mac's `shouldPresentNotification` pattern).

import AppKit
import OSLog
import UserNotifications

private let log = Logger.limpid("notifications")

@MainActor
final class LimpidNotificationManager {
    private let center = UNUserNotificationCenter.current()
    private var rateLimiter = RateLimiter(maxPerSecond: 5)
    private let historyStore: NotificationHistoryStore

    init(historyStore: NotificationHistoryStore) {
        self.historyStore = historyStore
        requestPermission()
    }

    private func requestPermission() {
        // We fire the OS prompt at init time, but intentionally do not
        // cache the `granted` result. Gating `send()` on a cached flag
        // races with the async callback — notifications that arrive
        // before the user answers (rapid command finishes at launch,
        // OSC 9 from a restored session) would be silently dropped.
        // `center.add(request:)` already rejects unauthorized requests
        // and surfaces them through the existing error log there.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                log.error("notification permission error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deliver a notification originating from `paneID`. `requireFocus`
    /// is stamped onto the request's userInfo so the
    /// `UNUserNotificationCenterDelegate` can suppress the banner while
    /// the source pane is focused and the window is key — i.e. when the
    /// user can already see the output that triggered the alert.
    func send(
        title: String,
        body: String,
        paneID: UUID,
        tabID: UUID? = nil,
        containerID: ContainerID? = nil,
        requireFocus: Bool = true,
        kind: NotificationEntry.Kind = .desktop,
        tabTitleSnapshot: String? = nil,
        containerLabel: String? = nil,
        exitCode: Int? = nil,
        durationSeconds: Double? = nil
    ) {
        // Always log the entry to the in-app history, even if macOS
        // declines to present the banner — the history panel is the
        // user's reliable backstop.
        let sanitizedTitle = NotificationSanitizer.sanitize(title)
        let sanitizedBody = NotificationSanitizer.sanitize(body)
        historyStore.record(
            NotificationEntry(
                kind: kind,
                paneID: paneID,
                tabTitleSnapshot: tabTitleSnapshot,
                containerLabel: containerLabel,
                title: sanitizedTitle,
                body: sanitizedBody,
                exitCode: exitCode,
                durationSeconds: durationSeconds
            )
        )

        guard rateLimiter.allow(key: paneID) else {
            log.debug("rate-limited notification for pane \(paneID, privacy: .public)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = sanitizedTitle
        content.body = sanitizedBody
        content.sound = .default
        // userInfo carries the routing keys the tap handler needs:
        // paneID first, then tabID, then containerID as a JSON blob
        // (ContainerID is an enum with associated values, so it can't
        // ride in userInfo as a primitive). `kind` is informational
        // for now — kept so future tap categories (bell vs command
        // finished vs OSC 9/777) can branch without re-deriving the
        // origin.
        var userInfo: [String: Any] = [
            "paneID": paneID.uuidString,
            "requireFocus": requireFocus,
            "kind": kind.rawValue
        ]
        if let tabID {
            userInfo["tabID"] = tabID.uuidString
        }
        if let containerID,
           let data = try? JSONEncoder().encode(containerID),
           let json = String(data: data, encoding: .utf8)
        {
            userInfo["containerJSON"] = json
        }
        content.userInfo = userInfo

        // Pin the request identifier to the pane id so back-to-back
        // alerts from the same pane replace the previous banner in
        // place instead of stacking up in Notification Center —
        // UNUserNotificationCenter replaces a delivered notification
        // when a new request reuses its identifier.
        let request = UNNotificationRequest(
            identifier: paneID.uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                log.error("notification deliver failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Tell the Dock to bounce, drawing the user's attention without
    /// stealing focus. Use sparingly — fire only on the *first* unread
    /// notification for a tab.
    func bounceDockIcon() {
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Reflect the total unread count across all panes onto the Dock
    /// tile's badge. Set to 0 to clear (the tile renders empty
    /// instead of "0"). Called from `WindowSession.startBadgeSync` on
    /// every `.surfaceViewUnreadChanged`.
    func setDockBadge(unreadCount: Int) {
        // Use `NSApplication.shared` rather than the implicitly-
        // unwrapped `NSApp` global, which can still be nil while the
        // SwiftUI app finishes booting.
        let label = unreadCount > 0 ? String(unreadCount) : ""
        NSApplication.shared.dockTile.badgeLabel = label.isEmpty ? nil : label
    }
}

// MARK: - Rate limiter

/// Sliding-window rate limiter: at most `maxPerSecond` events per key
/// within the trailing one-second window.
struct RateLimiter {
    let maxPerSecond: Int
    private var recentEvents: [UUID: [Date]] = [:]

    init(maxPerSecond: Int) {
        self.maxPerSecond = maxPerSecond
    }

    mutating func allow(key: UUID) -> Bool {
        let threshold = Date().addingTimeInterval(-1)
        var events = (recentEvents[key] ?? []).filter { $0 > threshold }
        defer { recentEvents[key] = events }
        guard events.count < maxPerSecond else { return false }
        events.append(Date())
        return true
    }
}
