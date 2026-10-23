// NotificationRoute.swift
// Limpid — where opening a notification, or its history row, takes the person.

import Foundation

/// What a notification or a history row points at, from most to least
/// specific. Every field is optional because the notification can outlive
/// any of them.
struct NotificationTarget: Equatable {
    var requestKey: ApprovalKey?
    var runtimeID: String?
    var paneID: UUID?
    var tabID: UUID?
    var containerID: ContainerID?

    init(
        requestKey: ApprovalKey? = nil,
        runtimeID: String? = nil,
        paneID: UUID? = nil,
        tabID: UUID? = nil,
        containerID: ContainerID? = nil
    ) {
        self.requestKey = requestKey
        self.runtimeID = runtimeID
        self.paneID = paneID
        self.tabID = tabID
        self.containerID = containerID
    }

    init(_ payload: NotificationTapPayload) {
        self.init(
            requestKey: payload.requestKey,
            runtimeID: payload.runtimeID,
            paneID: payload.paneID,
            tabID: payload.tabID,
            containerID: payload.containerID
        )
    }

    /// A history row keeps no tab or container, only its pane.
    init(_ entry: NotificationEntry) {
        self.init(requestKey: entry.requestKey, runtimeID: entry.runtimeID, paneID: entry.paneID)
    }
}

/// Where a notification takes the person.
///
/// A request that can still be answered on its card opens the card, and
/// the window and pane stay as they are. Anything else (a request handed
/// to the TUI, timed out, or settled; a Codex question; a stop; a finished
/// turn) opens the pane of the agent that raised it, followed to where it
/// runs now, and failing that the first of pane, tab, and container that
/// still exists.
enum NotificationRoute: Equatable {
    case card(ApprovalKey)
    case runtime(String)
    case pane(UUID)
    case tab(UUID)
    case container(ContainerID)

    /// What the app can tell about the targets now.
    struct Facts {
        /// Whether the request can be answered on its card: held or after a
        /// failed send, and a kind Limpid answers (not a Codex question).
        var opensCard: (ApprovalKey) -> Bool
        /// Whether the runtime still runs in a pane that is in a tab.
        var isRuntimeShown: (String) -> Bool
        var isPaneAlive: (UUID) -> Bool
        var isTabAlive: (UUID) -> Bool
        var isContainerAlive: (ContainerID) -> Bool
    }

    /// The first route that still leads somewhere, or `nil` when nothing
    /// the notification named is left.
    static func first(for target: NotificationTarget, facts: Facts) -> Self? {
        if let key = target.requestKey, facts.opensCard(key) {
            return .card(key)
        }
        if let runtimeID = target.runtimeID, facts.isRuntimeShown(runtimeID) {
            return .runtime(runtimeID)
        }
        if let paneID = target.paneID, facts.isPaneAlive(paneID) {
            return .pane(paneID)
        }
        if let tabID = target.tabID, facts.isTabAlive(tabID) {
            return .tab(tabID)
        }
        if let containerID = target.containerID, facts.isContainerAlive(containerID) {
            return .container(containerID)
        }
        return nil
    }
}
