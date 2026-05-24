// NotificationHistoryPresentation.swift
// Limpid — popover visibility state for the notification history panel.
//
// Carved out of `NotificationHistoryStore` so the "data" (entries +
// persistence) and the "UI state" (is the popover visible?) live in
// separate observable objects. The bell button in the sidebar and the
// segmented chrome capsule both bind against this single instance so
// either entry point toggles the same popover.

import Foundation
import Observation

@MainActor
@Observable
final class NotificationHistoryPresentation {
    /// Drives every notification-history popover's `isPresented` binding.
    var isPresented: Bool = false

    init() {}
}
