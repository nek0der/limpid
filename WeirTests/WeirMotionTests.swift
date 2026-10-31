// WeirMotionTests.swift
// Weir — what the app's own motions keep under Reduce Motion.

import SwiftUI
import Testing
@testable import Weir

struct WeirMotionTests {
    @Test func equalizingPanes_eases_unlessReduceMotionIsOn() {
        #expect(WeirMotion.expandAnimation(reduceMotion: false) == WeirMotion.expand)
        // The panes take their new sizes at once: the tween is decoration.
        #expect(WeirMotion.expandAnimation(reduceMotion: true) == nil)
    }
}
