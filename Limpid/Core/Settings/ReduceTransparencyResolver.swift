// ReduceTransparencyResolver.swift
// Limpid — folds the user's `transparencyEnabled` toggle together with
// the macOS accessibility flag into the single boolean the UI needs.
// Wraps the AppKit accessibility flag in an `@Observable` so SwiftUI
// re-renders the slab fill the instant the user toggles macOS's System
// Settings → Accessibility → Display → Reduce Transparency.
//
// The system flag always wins: when "Reduce Transparency" is on, AppKit
// renders vibrancy opaque and strips Liquid Glass regardless of our
// request, so the user toggle only matters while the system flag is
// off. `systemReducesTransparency` is exposed so the Settings UI can
// disable the toggle (and explain why) in that state.
//
// The store lives in the environment alongside `SettingsStore` so
// `LiquidGlassSlab` consumers can read `.shouldReduceTransparency`
// without threading both inputs through every modifier call.

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ReduceTransparencyResolver {
    /// Final boolean — `true` means slabs should render solid
    /// (transparency reduced). Recomputed whenever the user-facing
    /// setting OR the system accessibility flag changes.
    private(set) var shouldReduceTransparency: Bool = false

    /// Mirrors the live macOS accessibility flag. The Settings toggle is
    /// meaningless while this is true (the OS forces opacity), so the UI
    /// disables it and shows an explanation.
    private(set) var systemReducesTransparency: Bool = false

    private var userEnabled: Bool = true
    @ObservationIgnored
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init() {
        recompute()
        // NSWorkspace posts this notification on every system
        // accessibility toggle change — but only on its *own*
        // notification center, never `NotificationCenter.default`, so
        // we must observe `NSWorkspace.shared.notificationCenter` or the
        // callback never fires. Hop to the main actor so the recompute
        // and any downstream SwiftUI invalidation runs on the right
        // context.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recompute()
            }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Wire the user's preference into the resolver. Call this from
    /// `AppState.startSettingsConfigSync` so the resolver tracks the
    /// SettingsStore value over the app's lifetime.
    func apply(userEnabled: Bool) {
        guard userEnabled != self.userEnabled else { return }
        self.userEnabled = userEnabled
        recompute()
    }

    private func recompute() {
        systemReducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // Glass shows only when the user wants it AND the OS allows it.
        // Either opting out (`!userEnabled`) or the system flag forces
        // the opaque path.
        shouldReduceTransparency = !userEnabled || systemReducesTransparency
    }
}
