// SupervisionSegmentedPickerTests.swift
// Weir — the segmented choice's pill: it moves only on a change of the choice, sideways at one width, eased without overshoot; and its
// arrow keys.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@MainActor
struct SupervisionSegmentedPickerTests {
    typealias Picker = SupervisionSegmentedPicker<Int>
    private static let now = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func thePill_movesOnlyWhenTheSelectionChanges() {
        let resting = SegmentPillSlide.resting(at: 1)
        // The same segment again (a redraw, the sheet growing around the
        // control) leaves the pill as it is.
        #expect(SegmentPillSlide.after(selecting: 1, previously: 1, current: resting, now: Self.now, reduceMotion: false) == resting)
        #expect(SegmentPillSlide.after(selecting: nil, previously: 1, current: resting, now: Self.now, reduceMotion: false) == resting)
        let slide = SegmentPillSlide.after(selecting: 0, previously: 1, current: resting, now: Self.now, reduceMotion: false)
        #expect(slide.from == 1)
        #expect(slide.to == 0)
        #expect(slide.start == Self.now)
        #expect(slide.duration == WeirMotion.segmentSlideDuration)
    }

    @Test func withReduceMotion_thePillStillSlides_shorter() {
        let slide = SegmentPillSlide.after(
            selecting: 1,
            previously: 0,
            current: .resting(at: 0),
            now: Self.now,
            reduceMotion: true
        )
        #expect(slide.duration == WeirMotion.reducedSegmentSlideDuration)
        #expect(slide.duration > 0)
        #expect(slide.duration < WeirMotion.segmentSlideDuration)
    }

    @Test func aSlide_easesFromItsSegmentToTheNext_withoutPassingEither() {
        let slide = SegmentPillSlide(from: 1, to: 0, start: Self.now, duration: 0.24)
        #expect(slide.position(at: Self.now) == 1)
        #expect(slide.position(at: Self.now.addingTimeInterval(-1)) == 1)
        #expect(abs(slide.position(at: Self.now.addingTimeInterval(0.12)) - 0.5) < 1e-6)
        #expect(abs(slide.position(at: Self.now.addingTimeInterval(0.24))) < 1e-6)
        #expect(slide.position(at: Self.now.addingTimeInterval(5)) == 0)
        // Every 60fps frame: always between the two segments, always
        // moving the same way, never back.
        var previous = 1.0
        for frame in 0...20 {
            let position = slide.position(at: Self.now.addingTimeInterval(Double(frame) / 60))
            #expect((0...1).contains(position))
            #expect(position <= previous)
            previous = position
        }
    }

    @Test func aSecondClickMidSlide_turnsThePillFromWhereItIs() {
        let first = SegmentPillSlide(from: 0, to: 1, start: Self.now, duration: 0.24)
        let midway = Self.now.addingTimeInterval(0.12)
        let second = SegmentPillSlide.after(selecting: 0, previously: 1, current: first, now: midway, reduceMotion: false)
        #expect(second.from == first.position(at: midway))
        #expect(second.to == 0)
    }

    @Test func thePill_isOneSegmentWide_whateverItsPosition() {
        // The width comes from the track alone, never from the slide.
        #expect(SegmentPillSlide.segmentWidth(trackWidth: 440, count: 2) == 220)
        #expect(SegmentPillSlide.segmentWidth(trackWidth: 300, count: 3) == 100)
        #expect(SegmentPillSlide.segmentWidth(trackWidth: 300, count: 0) == 300)
    }

    @Test func theEasing_startsAndEndsStill_andStaysWithinItsRange() {
        #expect(SegmentPillSlide.easeInOut(0) == 0)
        #expect(SegmentPillSlide.easeInOut(1) == 1)
        #expect(SegmentPillSlide.easeInOut(0.5) == 0.5)
        #expect(SegmentPillSlide.easeInOut(0.05) < 0.05)
        #expect(SegmentPillSlide.easeInOut(0.95) > 0.95)
    }

    /// An arrow moves one segment and keeps the key; at an end it moves
    /// nowhere but still keeps the key, so the arrow does not carry the
    /// focus out of the control; while disabled, or with no segment chosen,
    /// the arrow goes on.
    @Test(arguments: [
        (Int?(0), 1, 3, true, Picker.KeyStep(next: 1, isHandled: true)),
        (2, -1, 3, true, .init(next: 1, isHandled: true)),
        (0, -1, 2, true, .init(next: nil, isHandled: true)),
        (1, 1, 2, true, .init(next: nil, isHandled: true)),
        (1, 1, 3, false, .init(next: nil, isHandled: false)),
        (nil, 1, 3, true, .init(next: nil, isHandled: false))
    ])
    func anArrow_movesOneSegmentInside_andKeepsTheKeyWhileEnabledAndChosen(
        from: Int?,
        by step: Int,
        count: Int,
        isEnabled: Bool,
        expected: Picker.KeyStep
    ) {
        #expect(Picker.keyStep(from: from, by: step, count: count, isEnabled: isEnabled) == expected)
    }

    /// A segment that takes no choice is passed over, to the next one that
    /// does; with none left that way, the arrow stays, keeping the key.
    @Test func anArrow_passesOverASegmentThatTakesNoChoice() {
        let isThirdOff = { (index: Int) in index != 2 }
        #expect(Picker.keyStep(from: 1, by: 1, count: 4, isEnabled: true, isSegmentEnabled: isThirdOff) == .init(next: 3, isHandled: true))
        #expect(Picker.keyStep(from: 3, by: -1, count: 4, isEnabled: true, isSegmentEnabled: isThirdOff) == .init(next: 1, isHandled: true))
        #expect(Picker.keyStep(from: 1, by: 1, count: 3, isEnabled: true, isSegmentEnabled: isThirdOff) == .init(
            next: nil,
            isHandled: true
        ))
    }

    /// At its ideal size each segment is as wide as the widest segment's
    /// words, so a long label is never cut under the pill beside it; given
    /// a width, the segments share it evenly, as the pill does.
    @Test func theSegments_atTheirIdealSize_areEachAsWideAsTheWidest() {
        let short = Text(verbatim: "Timeline")
        let long = Text(verbatim: "By Conversation")
        let longWidth = NSHostingView(rootView: long.fixedSize()).fittingSize.width
        let row = NSHostingView(rootView: EqualSegmentsLayout {
            short.frame(maxWidth: .infinity)
            long.frame(maxWidth: .infinity)
        }.fixedSize())

        #expect(abs(row.fittingSize.width - 2 * longWidth) < 0.5, "\(row.fittingSize.width) against \(longWidth)")
    }
}
