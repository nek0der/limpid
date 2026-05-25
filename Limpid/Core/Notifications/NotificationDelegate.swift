// NotificationDelegate.swift
// Limpid — UN delegate that filters foreground presentation. Inspired by
// Ghostty mac's `shouldPresentNotification` in `Ghostty.App.swift`.

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
    /// AppState walks `paneID → tabID → containerID` in order so a
    /// stale notification (pane / tab / container deleted before
    /// the user tapped) still lands somewhere sensible instead of
    /// silently no-op'ing. Same `nonisolated(unsafe)` rationale as
    /// `registry`.
    nonisolated(unsafe) static var onTap: (@MainActor @Sendable (NotificationTapPayload) -> Void)?

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
    /// Calls `completionHandler` synchronously. The pre-F4 design hopped
    /// onto MainActor with `Task { ... }`, which delayed the response —
    /// macOS gives `willPresent` a tight window before falling back to
    /// the default behavior, so the deferred call could occasionally
    /// land too late and the banner would render anyway. The focus
    /// check below is a pure NSApp / NSWindow read with no state of
    /// its own, so calling it from `nonisolated` is fine.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let requireFocus = (userInfo["requireFocus"] as? Bool) ?? true
        let paneIDString = userInfo["paneID"] as? String
        let isPaneFocused = MainActor.assumeIsolated {
            LimpidNotificationDelegate.isPaneFocused(paneIDString: paneIDString)
        }
        if requireFocus, isPaneFocused {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
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
        let onTap = LimpidNotificationDelegate.onTap
        Task { @MainActor in
            // Bring Limpid forward even if the payload is empty — a
            // stale notification (pre-tap-plumbing or after the
            // origin pane / tab / container was deleted) should
            // still act like the system default.
            NSApp.activate(ignoringOtherApps: true)
            onTap?(payload)
            completionHandler()
        }
    }

    /// Coarse "is some Limpid window currently focused" check.
    /// Kept around for the GhosttyEventCoordinator paths that already
    /// own a `SurfaceView` and want to refine with their own
    /// `firstResponder === view` test — they conjunct this with the
    /// view check inline rather than re-implementing it.
    @MainActor
    static var isKeyAndFocused: Bool {
        NSApp.keyWindow != nil && NSApp.isActive
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
        guard NSApp.isActive, let keyWindow = NSApp.keyWindow else { return false }
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
        return view.window === keyWindow && keyWindow.firstResponder === view
    }
}

/// Routing payload the tap handler walks from most-specific to least-
/// specific. We re-derive every field from `userInfo` because the
/// notification may outlive the originating pane, tab, or container —
/// keeping each as an optional lets `AppState` fall back step by step
/// instead of silently failing when the deepest target is gone.
struct NotificationTapPayload {
    let paneID: UUID?
    let tabID: UUID?
    let containerID: ContainerID?

    init(userInfo: [AnyHashable: Any]) {
        self.paneID = (userInfo["paneID"] as? String).flatMap(UUID.init(uuidString:))
        self.tabID = (userInfo["tabID"] as? String).flatMap(UUID.init(uuidString:))
        self.containerID = (userInfo["containerJSON"] as? String)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ContainerID.self, from: $0) }
    }
}
