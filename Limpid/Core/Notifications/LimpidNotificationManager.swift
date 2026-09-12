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

    /// Agent history follows runtime handling, even when its source is
    /// visible. Non-agent events can be acknowledged immediately when
    /// they happen under the user's eyes.
    static func initialReadState(kind: NotificationEntry.Kind, isSourceVisible: Bool) -> Bool {
        isSourceVisible && kind.agentState == nil
    }

    /// Deliver a notification originating from `paneID`. `requireFocus`
    /// is stamped onto the request's userInfo so the
    /// `UNUserNotificationCenterDelegate` can suppress the banner while
    /// the source pane is focused and the window is key — i.e. when the
    /// user can already see the output that triggered the alert.
    ///
    /// `presentsBanner: false` records the history row only. Agent
    /// errors use it: the red lifecycle badge and the Waiting row are
    /// already loud, and the agent's own dialog explains the failure,
    /// so a third channel would only add noise — but the row still
    /// belongs in the log the user scrolls back through.
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
        durationSeconds: Double? = nil,
        runtimeID: String? = nil,
        eventToken: String? = nil,
        presentsBanner: Bool = true
    ) {
        // Always log the entry to the in-app history, even if macOS
        // declines to present the banner — the history panel is the
        // user's reliable backstop.
        //
        // The row starts out *read* when the user is looking at the
        // source pane right now. The history unread count is what the
        // toolbar bell and the Dock badge display, and a turn that
        // finished under the user's eyes is not something they still
        // need to be told about. The same focus test gates the banner
        // in `LimpidNotificationDelegate.willPresent`, so the two
        // channels agree on what "already seen" means.
        let sanitizedTitle = NotificationSanitizer.sanitize(title)
        let sanitizedBody = NotificationSanitizer.sanitize(body)
        let isSourceVisible = requireFocus
            && LimpidNotificationDelegate.isPaneFocused(paneIDString: paneID.uuidString)
        historyStore.record(
            NotificationEntry(
                kind: kind,
                paneID: paneID,
                tabTitleSnapshot: tabTitleSnapshot,
                containerLabel: containerLabel,
                title: sanitizedTitle,
                body: sanitizedBody,
                exitCode: exitCode,
                durationSeconds: durationSeconds,
                isRead: Self.initialReadState(kind: kind, isSourceVisible: isSourceVisible),
                runtimeID: runtimeID,
                eventToken: eventToken
            )
        )
        guard presentsBanner else { return }

        let rateLimitID = runtimeID?.split(separator: ":").last.flatMap { UUID(uuidString: String($0)) } ?? paneID
        guard rateLimiter.allow(key: rateLimitID) else {
            log.debug("rate-limited notification for pane \(paneID, privacy: .public)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = sanitizedTitle
        content.body = sanitizedBody
        content.sound = .default
        // userInfo carries the routing keys the tap handler needs. Agent
        // notifications resolve runtimeID first; paneID, tabID, and the
        // ContainerID JSON blob provide progressively wider fallbacks.
        // `kind` is informational for future notification categories.
        var userInfo: [String: Any] = [
            "paneID": paneID.uuidString,
            "requireFocus": requireFocus,
            "kind": kind.rawValue
        ]
        if let tabID {
            userInfo["tabID"] = tabID.uuidString
        }
        if let runtimeID {
            userInfo["runtimeID"] = runtimeID
        }
        if let containerID,
           let data = try? JSONEncoder().encode(containerID),
           let json = String(data: data, encoding: .utf8)
        {
            userInfo["containerJSON"] = json
        }
        content.userInfo = userInfo

        // Agent runs sharing a tmux client must not replace each other's
        // banners. Non-agent notifications retain the pane-level identity.
        let request = UNNotificationRequest(
            identifier: runtimeID ?? paneID.uuidString,
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
