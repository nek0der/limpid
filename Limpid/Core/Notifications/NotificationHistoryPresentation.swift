// NotificationHistoryPresentation.swift
// Limpid — visibility and anchor state for the notification history panel.
//
// Carved out of `NotificationHistoryStore` so the "data" (entries +
// persistence) and the "UI state" (is the panel visible?) live in
// separate observable objects. The bell button in the sidebar and the
// keyboard command both use this single instance so every entry point
// toggles the same window-level panel.

import Foundation
import Observation

@MainActor
@Observable
final class NotificationHistoryPresentation {
    /// Drives the window-level notification history panel.
    var isPresented: Bool = false

    /// Global frame of the bell that most recently rendered. ContentView
    /// converts it back to window coordinates to place the floating panel
    /// below the same control without a popover arrow.
    var anchorFrame: CGRect = .zero

    init() {}
}
