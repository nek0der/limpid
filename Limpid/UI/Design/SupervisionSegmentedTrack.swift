// SupervisionSegmentedTrack.swift
// Limpid — the drawing of a segmented control: its track, the sliding accent pill, and the labels cut by it.

import SwiftUI

/// This is a segmented track's size around its segments. The segments' own height
/// is the caller's, set on what it draws in both layers.
struct SegmentedTrackMetrics {
    /// This is how much of the track shows around the pill.
    let inset: CGFloat
    let cornerRadius: CGFloat

    /// This is the track's corner less its inset, so the pill's curve runs
    /// parallel to the track's.
    var pillCornerRadius: CGFloat {
        cornerRadius - inset
    }

    /// These are the sizes of the supervision window's segmented picker.
    static let standard = SegmentedTrackMetrics(
        inset: LimpidLayout.Supervision.segmentedInset,
        cornerRadius: LimpidLayout.Supervision.segmentedCornerRadius
    )
}

/// This is what a segmented control draws, and nothing it does: the track, the
/// accent pill on the chosen segment and its slide, and the labels in two
/// layers cut by the pill. The caller brings the segments themselves (their
/// buttons, hover, focus, and keys), so a control can choose as it needs to
/// while every one of them reads alike.
///
/// `SupervisionSegmentedPicker` draws through this, and so do the approval
/// card's question tabs, whose own drawing once filled the pill with the raw
/// accent and set white words on it: a light accent then lost its words,
/// where the picker's colors hold their contrast.
///
/// The pill is placed from two numbers only: the track's width, split
/// equally among the segments, and its position, a segment index that may
/// be fractional mid-slide. Its width is the segment's, always, and its
/// height the track's, so it can only move sideways within the control. The
/// slide runs on its own clock (`SegmentPillSlide`, drawn through a
/// `TimelineView`) rather than through `withAnimation`. A first version
/// animated the pill in a transaction and measured each segment's frame;
/// the new worktree sheet changes its rows and its height in the same
/// update as its location, so that transaction animated the rows (drawn
/// over each other mid-move), the sheet's resize, and the pill between
/// frames measured before and after the layout changed (stretched over
/// both segments, then sprung past its width). With no animated
/// transaction anywhere in the control, nothing around it is animated by
/// its slide, and nothing around it can bend the slide.
///
/// The labels are drawn twice, in the text color (`segment`) and in the
/// pill's label color (`selectedLabel`), each layer cut by the same moving
/// pill: what the pill covers at any moment of the slide reads in the
/// pill's color, and the rest in the text color. A label whose color
/// flipped at once would vanish against the track until the pill reached it.
struct SupervisionSegmentedTrack<Segment: View, SelectedLabel: View>: View {
    let count: Int
    /// This is the segment the pill rests on or slides to; `nil` leaves the
    /// pill where it is.
    let selectedIndex: Int?
    let metrics: SegmentedTrackMetrics
    /// This is the segment at an index as it is drawn on the track, in the
    /// text color, with the caller's button, hover, and hit area.
    let segment: (Int) -> Segment
    /// This is the segment's label again, as the pill shows it, in the color
    /// it is given (the pill's label color). It is drawn only, never
    /// hit-tested.
    let selectedLabel: (Int, Color) -> SelectedLabel

    /// The store is optional so a view hosted without it (a test, a preview)
    /// draws the default accent rather than stopping.
    @Environment(SettingsStore.self) private var settings: SettingsStore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// This holds where the pill is and where it is going; only a change of
    /// the selection changes it (`SegmentPillSlide.after`).
    @State private var slide: SegmentPillSlide
    /// This is true while the clock runs, which is only while a slide is
    /// under way, so a resting control redraws only when something changes.
    @State private var isSliding = false

    init(
        count: Int,
        selectedIndex: Int?,
        metrics: SegmentedTrackMetrics = .standard,
        @ViewBuilder segment: @escaping (Int) -> Segment,
        @ViewBuilder selectedLabel: @escaping (Int, Color) -> SelectedLabel
    ) {
        self.count = count
        self.selectedIndex = selectedIndex
        self.metrics = metrics
        self.segment = segment
        self.selectedLabel = selectedLabel
        _slide = State(initialValue: .resting(at: selectedIndex ?? 0))
    }

    private var accent: AccentColor {
        settings?.settings.appearance.accentColor ?? .default
    }

    /// These are the primary button's fill and label, so the chosen segment and
    /// the sheets' primary buttons read as the same accent.
    private var colors: (fill: Color, label: Color) {
        SupervisionTokens.primaryButton(accent)
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.pillCornerRadius, style: .continuous)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isSliding)) { context in
            // At rest the pill is where the slide ends, whatever date a
            // paused timeline last gave.
            let position = isSliding ? slide.position(at: context.date) : slide.to
            layers(position: position)
        }
        .padding(metrics.inset)
        .background(
            // The track is `hover`, because the pill's edge is worked out
            // against it (`SupervisionTokens.segmentedPillEdge`).
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .fill(SupervisionTokens.hover.color)
        )
        .fixedSize(horizontal: false, vertical: true)
        // The whole control moves as one when the layout around it does
        // (a sheet changing height, the approval card moving): the pill and
        // the labels move together, and the pill's own offset stays sideways.
        .geometryGroup()
        .onChange(of: selectedIndex) { old, new in
            let next = SegmentPillSlide.after(
                selecting: new,
                previously: old,
                current: slide,
                now: Date(),
                reduceMotion: reduceMotion
            )
            slide = next
            isSliding = next.duration > 0
        }
        .task(id: slide) {
            // Stops the clock once the slide is over.
            guard slide.duration > 0 else { return }
            try? await Task.sleep(for: .seconds(slide.duration))
            if !Task.isCancelled {
                isSliding = false
            }
        }
    }

    /// Draws the segments with the pill at `position` under them.
    private func layers(position: Double) -> some View {
        // One width each, the widest's at the ideal size, as the pill is
        // one segment wide (`EqualSegmentsLayout`).
        EqualSegmentsLayout {
            ForEach(0..<count, id: \.self) { index in
                segment(index)
                    .frame(maxWidth: .infinity)
            }
        }
        // The segments' own labels, in the text color, are cut where the
        // pill is, so under it only the pill's labels show.
        .mask {
            Rectangle()
                .overlay {
                    atPill(pillShape, position: position).blendMode(.destinationOut)
                }
                .compositingGroup()
        }
        .background {
            atPill(
                pillShape
                    .fill(colors.fill)
                    // A light accent's fill differs from the track by a
                    // shade; the edge holds 3:1 against it.
                    .overlay(pillShape.strokeBorder(SupervisionTokens.segmentedPillEdge(accent), lineWidth: 1)),
                position: position
            )
        }
        .overlay {
            EqualSegmentsLayout {
                ForEach(0..<count, id: \.self) { index in
                    selectedLabel(index, colors.label)
                        .frame(maxWidth: .infinity)
                }
            }
            .mask { atPill(pillShape, position: position) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Places `content` as the pill: one segment wide and the track's height, at
    /// `position` segments from the leading edge. The pill, its edge, and
    /// both label masks are placed through here, so they cannot drift
    /// apart mid-slide.
    private func atPill(_ content: some View, position: Double) -> some View {
        GeometryReader { proxy in
            let width = SegmentPillSlide.segmentWidth(trackWidth: proxy.size.width, count: count)
            content
                .frame(width: width, height: proxy.size.height)
                .offset(x: width * position)
        }
    }
}
