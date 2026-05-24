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
    /// looking at would silently lose its notification. Falls back to
    /// the loose check when the pane id is missing (older notifications
    /// pre-dating this plumbing) or the registry isn't wired up.
    @MainActor
    static func isPaneFocused(paneIDString: String?) -> Bool {
        guard NSApp.isActive, let keyWindow = NSApp.keyWindow else { return false }
        guard let paneIDString,
              let paneID = UUID(uuidString: paneIDString),
              let registry,
              let view = registry.view(for: paneID)
        else {
            // No pane plumbing — degrade to "is any Limpid window
            // key" so we don't regress the pre-F4 behaviour.
            return true
        }
        return view.window === keyWindow && keyWindow.firstResponder === view
    }
}
