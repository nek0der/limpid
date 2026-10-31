// NotificationHistoryPlacementTests.swift
// Weir — the notification history opens beside the rail, inside the window.

import CoreGraphics
import Foundation
import Testing
@testable import Weir

struct NotificationHistoryPlacementTests {
    private static let window = CGSize(width: 1200, height: 800)
    private static let metrics = NotificationHistoryPlacement.Metrics(width: 400, preferredHeight: 520, inset: 12, gap: 6)

    /// Beside the button, and level with the top of the columns beside
    /// the rail rather than with the button, which sits lower.
    @Test func fromTheRail_itOpensBeside_levelWithTheColumnsTop() {
        let button = CGRect(x: 4, y: 132, width: 32, height: 32)
        let frame = NotificationHistoryPlacement.frame(anchor: button, columnTop: 44, container: Self.window, metrics: Self.metrics)
        #expect(frame == CGRect(x: 42, y: 44, width: 400, height: 520))
    }

    @Test func nearTheBottom_itRisesToFit_andAShortWindowShortensIt() {
        let low = CGRect(x: 4, y: 700, width: 32, height: 32)
        let raised = NotificationHistoryPlacement.frame(anchor: low, columnTop: 700, container: Self.window, metrics: Self.metrics)
        // The window height less the inset and the panel.
        #expect(raised.minY == 268)
        #expect(raised.maxY == 788)

        let short = CGSize(width: 1200, height: 400)
        let squeezed = NotificationHistoryPlacement.frame(anchor: low, columnTop: 44, container: short, metrics: Self.metrics)
        #expect(squeezed.minY == 12)
        #expect(squeezed.height == 376)
        // Never above the inset, whatever the columns' top.
        #expect(NotificationHistoryPlacement.frame(anchor: low, columnTop: 0, container: Self.window, metrics: Self.metrics).minY == 12)
    }

    @Test func aRailNearTheTrailingEdge_pullsThePanelIn_andANarrowWindowPinsItToTheInset() {
        let farRight = CGRect(x: 1000, y: 132, width: 32, height: 32)
        let pulled = NotificationHistoryPlacement.frame(anchor: farRight, columnTop: 44, container: Self.window, metrics: Self.metrics)
        #expect(pulled.maxX == 1188)

        let narrow = CGSize(width: 300, height: 800)
        let pinned = NotificationHistoryPlacement.frame(anchor: farRight, columnTop: 44, container: narrow, metrics: Self.metrics)
        #expect(pinned.minX == 12)
    }
}
