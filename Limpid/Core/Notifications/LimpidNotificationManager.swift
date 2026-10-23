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
    /// The agents' banners held back since `holdAgentBanners`, posted as one
    /// when the hold ends. Nil while nothing is held.
    private var heldAgentBanners: HeldBanners<UNNotificationRequest>?
    /// The identifier of the banner that stands for what arrived around a
    /// wake.
    static let summaryIdentifier = "attention-summary"
    /// The app locale, which every notification's text is written in. A
    /// banner and its history row are text outside SwiftUI, written once,
    /// so the producers resolve them in the language the app shows at the
    /// moment of the event; reading it here gives them all one source.
    let appLocale: @MainActor () -> Locale

    init(historyStore: NotificationHistoryStore, appLocale: @escaping @MainActor () -> Locale) {
        self.historyStore = historyStore
        self.appLocale = appLocale
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
                log.error("notification permission error: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Agent history follows runtime handling, even when its source is
    /// visible. Non-agent events can be acknowledged immediately when
    /// they happen under the user's eyes.
    static func initialReadState(kind: NotificationEntry.Kind, isSourceVisible: Bool) -> Bool {
        isSourceVisible && kind.agentState == nil
    }

    /// Deliver a notification originating from `paneID` (`nil` for a
    /// request no pane is known for). `requireFocus`
    /// is stamped onto the request's userInfo so the
    /// `UNUserNotificationCenterDelegate` can suppress the banner while
    /// the source pane is focused and the window is key — i.e. when the
    /// user can already see the output that triggered the alert.
    ///
    /// `subtitle` is the banner's alone: for an agent, where it works,
    /// which the history row already keeps as `containerLabel`.
    ///
    /// `presentsBanner: false` records the history row only. Agent
    /// errors use it: the red lifecycle badge and the attention item are
    /// already loud, and the agent's own dialog explains the failure,
    /// so a third channel would only add noise — but the row still
    /// belongs in the log the user scrolls back through.
    func send(
        title: String,
        subtitle: String? = nil,
        body: String,
        paneID: UUID?,
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
        requestKey: ApprovalKey? = nil,
        event: NotificationEvent? = nil,
        presentsBanner: Bool = true
    ) {
        // Always log the entry to the in-app history, even if macOS
        // declines to present the banner — the history panel is the
        // user's reliable backstop.
        //
        // The row starts out *read* when the user is looking at the
        // source pane right now. The history unread count is what the
        // rail's button and the Unread filter display, and a turn that
        // finished under the user's eyes is not something they still
        // need to be told about. For a command the same focus test gates
        // the banner in `LimpidNotificationDelegate.willPresent`; an
        // agent's row starts unread whatever the focus, and its banner is
        // gated by what the person can see.
        let sanitizedTitle = NotificationSanitizer.sanitize(title)
        let sanitizedBody = NotificationSanitizer.sanitize(body)
        let isSourceVisible = requireFocus
            && LimpidNotificationDelegate.isPaneFocused(paneIDString: paneID?.uuidString)
        historyStore.record(
            NotificationEntry(
                kind: kind,
                paneID: paneID,
                tabTitleSnapshot: tabTitleSnapshot,
                containerLabel: containerLabel,
                containerID: containerID,
                title: sanitizedTitle,
                body: sanitizedBody,
                exitCode: exitCode,
                durationSeconds: durationSeconds,
                isRead: Self.initialReadState(kind: kind, isSourceVisible: isSourceVisible),
                runtimeID: runtimeID,
                eventToken: eventToken,
                requestKey: requestKey,
                event: event
            )
        )
        guard presentsBanner else { return }

        // A request's banner is never rate-limited away: each one is
        // something to answer.
        let rateLimitID = runtimeID?.split(separator: ":").last.flatMap { UUID(uuidString: String($0)) } ?? paneID
        if requestKey == nil, let rateLimitID, !rateLimiter.allow(key: rateLimitID) {
            log.debug("rate-limited notification for pane \(rateLimitID, privacy: .public)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = sanitizedTitle
        if let subtitle {
            content.subtitle = NotificationSanitizer.sanitize(subtitle)
        }
        content.body = sanitizedBody
        content.sound = .default
        // userInfo carries the routing keys the tap handler needs. Agent
        // notifications resolve runtimeID first; paneID, tabID, and the
        // ContainerID JSON blob provide progressively wider fallbacks.
        // `kind` is informational for future notification categories.
        var userInfo: [String: Any] = [
            NotificationPayloadKey.requireFocus: requireFocus,
            NotificationPayloadKey.kind: kind.rawValue
        ]
        if let paneID {
            userInfo[NotificationPayloadKey.paneID] = paneID.uuidString
        }
        if let tabID {
            userInfo[NotificationPayloadKey.tabID] = tabID.uuidString
        }
        if let runtimeID {
            userInfo[NotificationPayloadKey.runtimeID] = runtimeID
        }
        if let containerID,
           let data = try? JSONEncoder().encode(containerID),
           let json = String(data: data, encoding: .utf8)
        {
            userInfo[NotificationPayloadKey.containerJSON] = json
        }
        if let requestKey,
           let data = try? JSONEncoder().encode(requestKey),
           let json = String(data: data, encoding: .utf8)
        {
            userInfo[NotificationPayloadKey.requestKeyJSON] = json
        }
        content.userInfo = userInfo

        // Agent runs sharing a tmux client must not replace each other's
        // banners. Non-agent notifications retain the pane-level identity.
        // A request's banner has its own, so it can be taken back once the
        // request can no longer be answered (`removeBanner(for:)`).
        let request = UNNotificationRequest(
            identifier: requestKey.map(Self.bannerIdentifier) ?? runtimeID ?? paneID?.uuidString ?? UUID().uuidString,
            content: content,
            trigger: nil
        )

        if kind.agentState != nil, heldAgentBanners != nil {
            heldAgentBanners?.hold(request, identifier: request.identifier)
            return
        }
        post(request)
    }

    /// What decides whether a banner reaches the person now. Focus is
    /// left unknown: reading it takes an entitlement and a consent Limpid
    /// does not ask for (`NotificationDeliveryStatus.Focus.unknown`).
    func deliveryStatus() async -> NotificationDeliveryStatus {
        let permission = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: Self.permission(
                    for: settings.authorizationStatus,
                    alertStyle: settings.alertStyle
                ))
            }
        }
        return NotificationDeliveryStatus(permission: permission)
    }

    /// The permission as the history shows it. What matters is whether a
    /// banner would reach the person: allowed with the alert style None,
    /// or the quiet trial, delivers to Notification Center only.
    nonisolated static func permission(
        for status: UNAuthorizationStatus,
        alertStyle: UNAlertStyle
    ) -> NotificationDeliveryStatus.Permission {
        switch status {
        case .authorized: alertStyle == .none ? .allowedWithoutBanners : .allowed
        case .provisional: .allowedWithoutBanners
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .notAsked
        }
    }

    /// One banner the person asked for, to see notifications arrive before
    /// stepping away. Posted directly rather than through `send`: it
    /// comes from no pane, writes no history row, and is never rate limited
    /// or held, since the person is waiting for it.
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Limpid"
        content.body = LocalizedStringResource(
            "Notifications from Limpid arrive like this.",
            comment: "Body of the test notification sent from the notification history"
        ).resolved(in: appLocale())
        content.sound = .default
        post(UNNotificationRequest(identifier: "test-notification", content: content, trigger: nil))
    }

    private func post(_ request: UNNotificationRequest) {
        center.add(request) { error in
            if let error {
                log.error("notification deliver failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Holds the agents' banners for `duration`, then posts what arrived as
    /// one: the single banner itself when only one came, or `summary` when
    /// several did (nothing when it returns nil). History rows are written
    /// as usual meanwhile. Used after the Mac wakes, when the events queued
    /// during sleep all land at once.
    func holdAgentBanners(for duration: Duration, summary: @escaping @MainActor () -> (title: String, body: String)?) {
        guard heldAgentBanners == nil else { return }
        heldAgentBanners = HeldBanners()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, let held = heldAgentBanners else { return }
            heldAgentBanners = nil
            switch held.outcome {
            case .nothing:
                break
            case let .single(banner):
                post(banner)
            case .summary:
                guard let text = summary() else { break }
                let content = UNMutableNotificationContent()
                content.title = NotificationSanitizer.sanitize(text.title)
                content.body = NotificationSanitizer.sanitize(text.body)
                content.sound = .default
                post(UNNotificationRequest(identifier: Self.summaryIdentifier, content: content, trigger: nil))
            }
        }
    }

    /// The banner identifier of a request's notification.
    static func bannerIdentifier(for key: ApprovalKey) -> String {
        "request:\(key.epoch.uuidString):\(key.runID.uuidString):\(key.requestID.uuidString)"
    }

    /// Takes back the banner of a request that can no longer be answered
    /// from it (it timed out, or was settled), so Notification Center does
    /// not keep offering it.
    func removeBanner(for key: ApprovalKey) {
        let identifier = Self.bannerIdentifier(for: key)
        heldAgentBanners?.drop(identifier: identifier)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Takes back a runtime's own banner (its hook's wait), which a
    /// request's banner replaces: a question's wait reaches Limpid before
    /// the request does.
    func removeRuntimeBanner(_ runtimeID: String) {
        heldAgentBanners?.drop(identifier: runtimeID)
        center.removeDeliveredNotifications(withIdentifiers: [runtimeID])
    }

    /// The identifier of the notification pending for `provider`'s usage
    /// limit reset; one per provider, so a later reset replaces it.
    static func usageLimitResetIdentifier(for provider: AgentKind) -> String {
        "usage-limit-reset.\(provider.rawValue)"
    }

    /// Has the system deliver "Claude's usage limit has reset" at `date`,
    /// for a person who asked for it. Scheduled with a calendar
    /// trigger so it arrives at that time across sleep; like the test
    /// banner it comes from no pane, writes no history row, and is not
    /// rate limited.
    func scheduleUsageLimitReset(for provider: AgentKind, at date: Date) {
        let locale = appLocale()
        let name = switch provider {
        // Product names, the same in every language.
        case .claude: "Claude"
        case .codex: "Codex"
        }
        let content = UNMutableNotificationContent()
        content.title = LocalizedStringResource(
            "\(name) usage limit has reset",
            comment: "Notification title: the agent's plan can be used again; the argument is Claude or Codex"
        ).resolved(in: locale)
        content.body = LocalizedStringResource(
            "Conversations can continue.",
            comment: "Notification body after an agent's usage limit reset"
        ).resolved(in: locale)
        content.sound = .default
        // With the time zone in the components the trigger is that instant,
        // not a wall clock time that a trip or a daylight saving change
        // would move.
        let components = Calendar.current.dateComponents(
            [.timeZone, .year, .month, .day, .hour, .minute, .second],
            from: date
        )
        post(UNNotificationRequest(
            identifier: Self.usageLimitResetIdentifier(for: provider),
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        ))
    }

    /// Withdraws the reset notification still pending for `provider`.
    func cancelUsageLimitReset(for provider: AgentKind) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.usageLimitResetIdentifier(for: provider)])
    }

    /// Takes back the wake summary once nothing it counted needs attention.
    func removeSummaryBanner() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.summaryIdentifier])
    }

    /// Tell the Dock to bounce, drawing the user's attention without
    /// stealing focus. Use sparingly — fire only on the *first* unread
    /// notification for a tab.
    func bounceDockIcon() {
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Shows `badge` on the Dock tile: the attention count, a dot, or
    /// nothing (the tile renders empty rather than "0"). Called by
    /// `DockBadgeSync` whenever the badge changes.
    func setDockBadge(_ badge: DockBadge) {
        // Use `NSApplication.shared` rather than the implicitly-
        // unwrapped `NSApp` global, which can still be nil while the
        // SwiftUI app finishes booting.
        NSApplication.shared.dockTile.badgeLabel = badge.label
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
