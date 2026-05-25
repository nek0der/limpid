// LimpidNotificationManager.swift
// Limpid — `UNUserNotificationCenter` integration with rate limiting.
//
// Adapted from Calyx (`Features/Notifications/NotificationManager.swift`,
// MIT). Two differences from the upstream:
//   1. Rate limiting keys on the pane id, not the tab id, so split
//      panes inside the same tab can each fire independently.
//   2. We hand the underlying `UNNotificationRequest` userInfo a
//      pane id + a `requireFocus` flag so the `UNUserNotificationCenterDelegate`
//      can decide whether to present the alert while the app is in
//      the foreground (Ghostty mac's `shouldPresentNotification` pattern).

import AppKit
import OSLog
import UserNotifications

private let log = Logger(subsystem: "dev.limpid", category: "notifications")

@MainActor
final class LimpidNotificationManager {
    private let center = UNUserNotificationCenter.current()
    private var rateLimiter = RateLimiter(maxPerSecond: 5)
    private var permissionGranted = false
    private let historyStore: NotificationHistoryStore

    init(historyStore: NotificationHistoryStore) {
        self.historyStore = historyStore
        requestPermission()
    }

    private func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                self.permissionGranted = granted
                if let error {
                    log.error("notification permission error: \(error.localizedDescription, privacy: .public)")
                }
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
        guard permissionGranted else { return }

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
           let json = String(data: data, encoding: .utf8) {
            userInfo["containerJSON"] = json
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
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
    /// stealing focus. Use sparingly — Calyx only fires this on the
    /// *first* unread notification for a tab.
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

/// Sliding-window rate limiter — at most `maxPerSecond` events per key
/// in any rolling 1-second window. Mirrors Calyx's helper verbatim.
struct RateLimiter {
    let maxPerSecond: Int
    private var windows: [UUID: [Date]]

    init(maxPerSecond: Int) {
        self.maxPerSecond = maxPerSecond
        self.windows = [:]
    }

    mutating func allow(key: UUID) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-1)

        var recent = windows[key, default: []]
        recent = recent.filter { $0 > cutoff }

        if recent.count >= maxPerSecond {
            windows[key] = recent
            return false
        }

        recent.append(now)
        windows[key] = recent
        return true
    }
}
