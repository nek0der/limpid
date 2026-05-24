// ReduceTransparencyResolver.swift
// Limpid — translates `TransparencyMode` (system / on / off) into
// the single boolean the UI layer actually needs. Wraps the AppKit
// accessibility flag in an `@Observable` so SwiftUI re-renders the
// slab fill the instant the user toggles macOS's System Settings →
// Accessibility → Display → Reduce Transparency.
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

    private var userMode: TransparencyMode = .system
    @ObservationIgnored
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init() {
        recompute()
        // NSWorkspace posts this notification on every system
        // accessibility toggle change. Hop to the main actor so the
        // recompute and any downstream SwiftUI invalidation runs on
        // the right context.
        observer = NotificationCenter.default.addObserver(
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
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Wire the user's preference into the resolver. Call this from
    /// `AppState.startSettingsConfigSync` so the resolver tracks the
    /// SettingsStore value over the app's lifetime.
    func apply(userMode: TransparencyMode) {
        guard userMode != self.userMode else { return }
        self.userMode = userMode
        recompute()
    }

    private func recompute() {
        let systemReduces = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        switch userMode {
        case .system: shouldReduceTransparency = systemReduces
        case .on: shouldReduceTransparency = false // forced translucent
        case .off: shouldReduceTransparency = true // forced opaque
        }
    }
}
