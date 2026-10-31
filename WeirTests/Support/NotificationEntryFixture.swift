// NotificationEntryFixture.swift
// Weir — one builder for the notification history rows the suites record.

import Foundation
@testable import Weir
@testable import WeirDomain

extension NotificationEntry {
    /// An unread desktop notification from no pane, recorded now, changed
    /// only where a test says.
    ///
    /// The initializer asks for the pane and tab snapshot of every row, which
    /// most tests have nothing to say about.
    static func test(
        id: UUID = UUID(),
        kind: Kind = .desktop,
        timestamp: Date = Date(),
        paneID: UUID? = nil,
        tabTitleSnapshot: String? = nil,
        containerLabel: String? = nil,
        containerID: ContainerID? = nil,
        title: String = "title",
        body: String = "body",
        exitCode: Int? = nil,
        durationSeconds: Double? = nil,
        isRead: Bool = false,
        runtimeID: String? = nil,
        eventToken: String? = nil,
        requestKey: ApprovalKey? = nil,
        event: NotificationEvent? = nil
    ) -> NotificationEntry {
        NotificationEntry(
            id: id,
            kind: kind,
            timestamp: timestamp,
            paneID: paneID,
            tabTitleSnapshot: tabTitleSnapshot,
            containerLabel: containerLabel,
            containerID: containerID,
            title: title,
            body: body,
            exitCode: exitCode,
            durationSeconds: durationSeconds,
            isRead: isRead,
            runtimeID: runtimeID,
            eventToken: eventToken,
            requestKey: requestKey,
            event: event
        )
    }
}
