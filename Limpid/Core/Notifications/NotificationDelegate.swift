// NotificationDelegate.swift
// Limpid — UN delegate that filters foreground notification presentation.

import AppKit
import UserNotifications

@MainActor
final class LimpidNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Registry lookup the delegate uses to resolve `userInfo["paneID"]`
    /// to the corresponding `SurfaceView`. Set by `AppState.init` —
    /// the delegate's `willPresent` callback runs synchronously on a
    /// system queue, so it can't reach back into AppState through the
    /// SwiftUI environment.
    nonisolated(unsafe) static var registry: (any SurfaceViewProviding)?

    /// Tap-handler closure invoked from `didReceive` with the full
    /// routing payload the notification's `userInfo` carried —
    /// AppState walks `runtimeID → paneID → tabID → containerID` so a
    /// tmux runtime follows its current attachment and a stale record still
    /// lands on the persisted fallback. Same `nonisolated(unsafe)` rationale
    /// as `registry`.
    nonisolated(unsafe) static var onTap: (@MainActor @Sendable (NotificationTapPayload) -> Void)?

    /// Whether the person can see where an agent's notification came from:
    /// any pane its runtime shows in, tmux attachments included,
    /// or else the pane the banner names. Decides an agent's banner: none
    /// while its source is in sight, whichever pane has the keyboard. Set
    /// by the app layer, which knows the windows. Nil until then, when the
    /// focus test decides as it does for command notifications. Same
    /// `nonisolated(unsafe)` rationale as `registry`.
    nonisolated(unsafe) static var isSourceSeen: (@MainActor (_ paneID: UUID?, _ runtimeID: String?) -> Bool)?

    override init() {
        super.init()
    }

    /// Wire this delegate into UNUserNotificationCenter exactly once.
    /// Call from `AppState.init` (or any equivalent boot path).
    /// UNUserNotificationCenter holds the delegate weakly, so the
    /// owning AppState must keep a strong reference for the app's
    /// lifetime.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called while Limpid is in the foreground and a notification is
    /// about to fire. We suppress the banner when the originating pane
    /// is the currently-focused one inside the key window — i.e. when
    /// the user can already see the output that produced the alert.
    ///
    /// `UNUserNotificationCenterDelegate` does not promise to invoke
    /// this on the main queue, so `MainActor.assumeIsolated` here
    /// would trap any time Apple drains the callback on its private
    /// queue. Hop through a `Task { @MainActor }` and call the
    /// completion handler from inside that hop — the focus read
    /// (`NSApp.keyWindow` / `firstResponder`) is main-thread-only, and
    /// the small dispatch latency is preferable to a release-build
    /// trap if the queue contract ever changes. `completionHandler` is
    /// `@Sendable` so crossing the actor boundary is safe.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let requireFocus = (userInfo[NotificationPayloadKey.requireFocus] as? Bool) ?? true
        let paneIDString = userInfo[NotificationPayloadKey.paneID] as? String
        let runtimeID = userInfo[NotificationPayloadKey.runtimeID] as? String
        let isAgent = (userInfo[NotificationPayloadKey.kind] as? String).flatMap(NotificationEntry.Kind.init(rawValue:))?.agentState != nil
        Task { @MainActor in
            let isPaneInSight: Bool = if isAgent, let isSourceSeen = LimpidNotificationDelegate.isSourceSeen {
                isSourceSeen(paneIDString.flatMap(UUID.init(uuidString:)), runtimeID)
            } else {
                LimpidNotificationDelegate.isPaneFocused(paneIDString: paneIDString)
            }
            if requireFocus, isPaneInSight {
                completionHandler([])
            } else {
                completionHandler([.banner, .sound])
            }
        }
    }

    /// Called when the user taps a delivered notification (banner,
    /// Notification Center entry, or Lock-Screen alert). We pull the
    /// pane id out of `userInfo` and hand off to the `onTap` closure
    /// that AppState wired up — it switches tabs, focuses the
    /// SurfaceView, and the existing active-tab observer handles
    /// markRead + Dock badge decrement. Without this handler the
    /// system default fires (just activates the app), so taps never
    /// reach the originating pane.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let payload = NotificationTapPayload(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            // Read on the main actor, so a tap that launched the app finds
            // the handler the attention list installs once it is up.
            let onTap = LimpidNotificationDelegate.onTap
            // Bring Limpid forward even if the payload is empty — a
            // stale notification (pre-tap-plumbing or after the
            // origin pane / tab / container was deleted) should
            // still act like the system default.
            NSApp.activate(ignoringOtherApps: true)
            onTap?(payload)
            completionHandler()
        }
    }

    /// True only when the surface view for `paneIDString` is the first
    /// responder of the key window. The previous heuristic just checked
    /// "is *some* Limpid window key", which suppressed banners for
    /// background panes in the same window — a tab the user wasn't
    /// looking at would silently lose its notification. Fails closed
    /// (returns `false`) when the pane id is missing or the registry
    /// isn't wired yet: a banner we maybe didn't need to show is
    /// recoverable, but a notification dropped on the floor is gone.
    @MainActor
    static func isPaneFocused(paneIDString: String?) -> Bool {
        guard NSApp.isActive, NSApp.keyWindow != nil else { return false }
        guard let paneIDString,
              let paneID = UUID(uuidString: paneIDString),
              let registry,
              let view = registry.view(for: paneID)
        else {
            // No pane plumbing — fail-closed (treat the pane as not
            // focused) so the banner shows. Suppressing on missing
            // metadata loses notifications silently, which is the
            // worse failure mode; showing one we maybe didn't need to
            // is recoverable (the user sees + dismisses it).
            return false
        }
        return isViewFocused(view)
    }

    /// True only when `view` is the first responder of the key window of the
    /// active app. The window check matters once the quick terminal can be
    /// key: a main-window pane is still its own window's first responder
    /// then, and treating it as focused would suppress its notifications
    /// and unread marks while the user is typing in the panel.
    @MainActor
    static func isViewFocused(_ view: SurfaceView) -> Bool {
        guard NSApp.isActive, let keyWindow = NSApp.keyWindow else { return false }
        return view.window === keyWindow && keyWindow.firstResponder === view
    }
}

/// Routing payload the tap handler walks from most-specific to least-
/// specific. We re-derive every field from `userInfo` because the
/// notification may outlive the originating pane, tab, or container —
/// keeping each as an optional lets `AppState` fall back step by step
/// instead of silently failing when the deepest target is gone.
struct NotificationTapPayload {
    let runtimeID: String?
    let paneID: UUID?
    let tabID: UUID?
    let containerID: ContainerID?
    /// The request a needs-input banner announced; see
    /// `NotificationEntry.requestKey`.
    let requestKey: ApprovalKey?

    init(userInfo: [AnyHashable: Any]) {
        self.runtimeID = userInfo[NotificationPayloadKey.runtimeID] as? String
        self.requestKey = (userInfo[NotificationPayloadKey.requestKeyJSON] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ApprovalKey.self, from: $0) }
        self.paneID = (userInfo[NotificationPayloadKey.paneID] as? String).flatMap(UUID.init(uuidString:))
        self.tabID = (userInfo[NotificationPayloadKey.tabID] as? String).flatMap(UUID.init(uuidString:))
        self.containerID = (userInfo[NotificationPayloadKey.containerJSON] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ContainerID.self, from: $0) }
    }
}

/// The keys of a banner's `userInfo`, which `LimpidNotificationManager`
/// writes and the delegate reads back when the banner shows or is clicked.
/// One list, so the writer and the reader cannot name a key two ways.
enum NotificationPayloadKey {
    static let requireFocus = "requireFocus"
    static let kind = "kind"
    static let paneID = "paneID"
    static let tabID = "tabID"
    static let runtimeID = "runtimeID"
    static let containerJSON = "containerJSON"
    static let requestKeyJSON = "requestKeyJSON"
}
