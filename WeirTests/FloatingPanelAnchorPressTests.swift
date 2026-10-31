// FloatingPanelAnchorPressTests.swift
// Weir — which presses the floating panel's event monitor takes for a press on the panel's anchor.

import AppKit
import Testing
@testable import Weir

struct FloatingPanelAnchorPressTests {
    /// An anchor just above a 100-point-tall panel, in the panel's own
    /// coordinates, which run down from its top.
    private let anchor = CGRect(x: 40, y: -20, width: 16, height: 16)

    @Test func unflippedView_turnsThePressOverBeforeComparing() {
        // 110 points up from the bottom of a 100-point view is 10 above its
        // top: -10 in the panel's coordinates, on the anchor.
        #expect(FloatingPanelEventMonitor.isPress(
            at: CGPoint(x: 48, y: 110),
            onAnchor: anchor,
            panelHeight: 100,
            isFlipped: false
        ))
        #expect(!FloatingPanelEventMonitor.isPress(
            at: CGPoint(x: 48, y: -10),
            onAnchor: anchor,
            panelHeight: 100,
            isFlipped: false
        ), "unturned, the same numbers would hit")
    }

    @Test func flippedView_comparesAsIs() {
        #expect(FloatingPanelEventMonitor.isPress(
            at: CGPoint(x: 48, y: -10),
            onAnchor: anchor,
            panelHeight: 100,
            isFlipped: true
        ))
        #expect(!FloatingPanelEventMonitor.isPress(
            at: CGPoint(x: 200, y: -10),
            onAnchor: anchor,
            panelHeight: 100,
            isFlipped: true
        ))
    }
}
