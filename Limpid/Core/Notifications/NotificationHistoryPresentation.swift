// NotificationHistoryPresentation.swift
// Limpid — whether the notification history panel is up.
//
// Carved out of `NotificationHistoryStore` so the "data" (entries +
// persistence) and the "UI state" (is the panel visible?) live in
// separate observable objects. Each window has its own
// (`ProjectWindowState.notificationHistory`): its rail button and the
// keyboard command aimed at it toggle that window's panel only.

import Foundation
import Observation

@MainActor
@Observable
final class NotificationHistoryPresentation {
    /// Drives the window-level notification history panel. Where it opens
    /// is each window's own (`ProjectWindowState.historyAnchor`).
    var isPresented: Bool = false

    init() {}
}
