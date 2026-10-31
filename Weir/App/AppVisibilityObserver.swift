// AppVisibilityObserver.swift
// Weir — tells the window registry whether Weir is in front and whether VoiceOver runs.

import AppKit

/// Feeds the app-wide facts of `AttentionVisibility` into the window
/// registry. In the app layer because both come from AppKit, which Core and
/// Presentation do not import; the registry only stores what it is told.
@MainActor
final class AppVisibilityObserver: NSObject {
    private weak var registry: WindowRegistry?
    private var voiceOverObservation: NSKeyValueObservation?

    init(registry: WindowRegistry) {
        self.registry = registry
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(activityChanged(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(activityChanged(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        // Read at once rather than through the observation's first callback,
        // which hops to the main actor later: until then a request could be
        // handed to the TUI with VoiceOver running.
        registry.voiceOverChanged(isRunning: NSWorkspace.shared.isVoiceOverEnabled)
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                // Read again on arrival, so changes that land out of order
                // still leave the current value.
                self?.registry?.voiceOverChanged(isRunning: NSWorkspace.shared.isVoiceOverEnabled)
            }
        }
        // `NSApplication.shared`, not `NSApp`: this runs inside `AppState.init`,
        // where `NSApp` may still be nil.
        registry.appActivityChanged(isActive: NSApplication.shared.isActive)
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func activityChanged(_ note: Notification) {
        registry?.appActivityChanged(isActive: NSApplication.shared.isActive)
    }
}
