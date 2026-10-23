// LimpidMotionTests.swift
// Limpid — what the app's own motions keep under Reduce Motion.

import SwiftUI
import Testing
@testable import Limpid

struct LimpidMotionTests {
    @Test func equalizingPanes_eases_unlessReduceMotionIsOn() {
        #expect(LimpidMotion.expandAnimation(reduceMotion: false) == LimpidMotion.expand)
        // The panes take their new sizes at once: the tween is decoration.
        #expect(LimpidMotion.expandAnimation(reduceMotion: true) == nil)
    }
}
