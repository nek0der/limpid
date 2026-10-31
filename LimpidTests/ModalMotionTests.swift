// ModalMotionTests.swift
// Limpid — how each kind of modal surface comes and goes, and what Reduce Motion keeps of each.

import SwiftUI
import Testing
@testable import Limpid

struct ModalMotionTests {
    private typealias Transition = ModalMotion.Transition
    private static let fade = Transition(fades: true, edge: nil, scale: nil)

    @Test func aFloatingPanel_fadesWithoutScaling_andKeepsItsFadeUnderReduceMotion() {
        for reduceMotion in [false, true] {
            #expect(ModalMotion.floatingPanel.transition(reduceMotion: reduceMotion) == Self.fade)
            #expect(ModalMotion.floatingPanel.animation(reduceMotion: reduceMotion) == LimpidMotion.floatingPanel)
        }
    }

    @Test func aPaneBar_comesDownFromTheTop_andOnlyFadesUnderReduceMotion() {
        #expect(ModalMotion.paneBar.transition(reduceMotion: false) == Transition(fades: true, edge: .top, scale: nil))
        #expect(ModalMotion.paneBar.transition(reduceMotion: true) == Self.fade)
        #expect(ModalMotion.paneBar.animation(reduceMotion: true) == LimpidMotion.floatingPanel)
    }

    @Test func theOverlay_scalesFromAlmostItsSize_andDropsOnlyTheScaleUnderReduceMotion() {
        #expect(ModalMotion.overlayPanel.transition(reduceMotion: false) == Transition(
            fades: true,
            edge: nil,
            scale: ModalMotion.overlayPanelScale
        ))
        #expect(ModalMotion.overlayPanelScale < 1)
        #expect(ModalMotion.overlayPanel.transition(reduceMotion: true) == Self.fade)
        // The fade is still animated: a sheet that blinks in reads as a glitch.
        #expect(ModalMotion.overlayPanel.animation(reduceMotion: true) == LimpidMotion.overlay)
    }

    @Test func theScrim_fadesWithItsOverlay_onTheSameCurve() {
        for reduceMotion in [false, true] {
            #expect(ModalMotion.overlayScrim.transition(reduceMotion: reduceMotion) == Self.fade)
            #expect(
                ModalMotion.overlayScrim.animation(reduceMotion: reduceMotion)
                    == ModalMotion.overlayPanel.animation(reduceMotion: reduceMotion)
            )
        }
    }

    @Test func aBanner_slidesUpFromTheBottom_andAppearsAtOnceUnderReduceMotion() {
        #expect(ModalMotion.transientBanner.transition(reduceMotion: false) == Transition(fades: true, edge: .bottom, scale: nil))
        #expect(ModalMotion.transientBanner.animation(reduceMotion: false) == LimpidMotion.transientBanner)
        // Reduce Motion stops the toast's animation, and the move
        // suggestion is drawn as a toast.
        #expect(ModalMotion.transientBanner.transition(reduceMotion: true) == .identity)
        #expect(ModalMotion.transientBanner.animation(reduceMotion: true) == nil)
    }

    /// The changes panel laid over the terminal fades as the history does;
    /// docked, it slides in from the trailing edge, and not at all under
    /// Reduce Motion.
    @Test func theChangesPanel_fadesWhenFloating_andSlidesWhenDocked() {
        for reduceMotion in [false, true] {
            #expect(ChangesPanelMotion.transition(isFloating: true, reduceMotion: reduceMotion) == Self.fade)
            #expect(ChangesPanelMotion.animation(isFloating: true, reduceMotion: reduceMotion) == LimpidMotion.floatingPanel)
        }
        #expect(ChangesPanelMotion.transition(isFloating: false, reduceMotion: false) == Transition(
            fades: true,
            edge: .trailing,
            scale: nil
        ))
        #expect(ChangesPanelMotion.animation(isFloating: false, reduceMotion: false) == LimpidMotion.sidebarToggle)
        #expect(ChangesPanelMotion.transition(isFloating: false, reduceMotion: true) == .identity)
        #expect(ChangesPanelMotion.animation(isFloating: false, reduceMotion: true) == nil)
    }

    /// Without `LIMPID_SLOW_MOTION` the tokens run at their own pace; a
    /// factor slows them, and one that is not a finite number of at least 1
    /// leaves them alone. Read from a handed-in environment, so a developer's
    /// shell does not decide this.
    @Test(arguments: [
        (nil, 1),
        ("10", 10),
        ("1", 1),
        ("0.5", 1),
        ("-3", 1),
        ("inf", 1),
        ("nan", 1),
        ("fast", 1)
    ] as [(String?, Double)])
    func thePace_comesFromAFactorOfAtLeastOne(_ factor: String?, _ pace: Double) {
        let environment = factor.map { ["LIMPID_SLOW_MOTION": $0] } ?? [:]
        #expect(LimpidMotion.pace(environment: environment) == pace)
    }
}
