// SupervisionSegmentedPicker.swift
// Limpid — the supervision window's segmented choice: a few fixed values side by side, the chosen one on a sliding accent pill.

import SwiftUI

/// A choice among two to four fixed values shown side by side,
/// the chosen one on a pill filled as the primary button is, which slides
/// to the next choice. The segments share the width they are given equally.
///
/// The supervision window builds a single choice one of two ways: this for
/// a few values, a pop-up menu for more. The new workspace's
/// location, the notification filters, and the review's list layout all
/// use it, so they look, mark the choice, and take ← → alike.
///
/// Not `.pickerStyle(.segmented)`: on macOS that is an `NSSegmentedControl`,
/// which swaps its highlight rather than moving it, and fills it with the
/// system's blue whatever accent the window uses, beside the accent's focus
/// ring and primary button.
///
/// The track, the pill and its slide, and the labels in two layers cut by
/// the pill are `SupervisionSegmentedTrack`'s, which the approval card's
/// question tabs draw through as well; this control adds the segments'
/// buttons, their hover, the keyboard, and VoiceOver.
struct SupervisionSegmentedPicker<Value: Hashable>: View {
    /// One segment: the value it chooses and its words.
    struct Option {
        let value: Value
        let title: Text
        /// The segment's own tooltip and VoiceOver value, for one that says
        /// more than its words (Unread: how many).
        var help: Text?
        var accessibilityValue: Text?
        /// Whether a dot follows the words (Unread while anything is
        /// unread). Drawn by the control rather than set in the words, so
        /// under the pill it takes the pill's label color, as the words do,
        /// and it stands on the middle of the words rather than on their
        /// baseline. Says nothing to VoiceOver: `accessibilityValue` does.
        var hasDot: Bool
        /// Whether the segment takes a choice. One that does not is faded
        /// and skipped by the arrows; its `help` says why, as a disabled
        /// menu item's tooltip would.
        var isEnabled: Bool

        init(
            _ value: Value,
            _ title: Text,
            help: Text? = nil,
            accessibilityValue: Text? = nil,
            hasDot: Bool = false,
            isEnabled: Bool = true
        ) {
            self.value = value
            self.title = title
            self.help = help
            self.accessibilityValue = accessibilityValue
            self.hasDot = hasDot
            self.isEnabled = isEnabled
        }
    }

    /// What an arrow key does: the segment it selects, if any, and whether
    /// the control keeps the key.
    struct KeyStep: Equatable {
        let next: Int?
        let isHandled: Bool
    }

    /// What VoiceOver calls the whole control, as the label beside it reads.
    let label: Text
    let options: [Option]
    @Binding var selection: Value

    @Environment(\.isEnabled) private var isEnabled
    @State private var hoveredIndex: Int?
    @FocusState private var isFocused: Bool

    /// Smaller words and less room around them, for a filter line or a
    /// panel's bar, where the full size would not fit four segments.
    let isCompact: Bool

    init(_ label: Text, selection: Binding<Value>, options: [Option], isCompact: Bool = false) {
        self.label = label
        _selection = selection
        self.options = options
        self.isCompact = isCompact
    }

    private var fontSize: LimpidFont.Supervision.Size {
        Self.fontSize(isCompact: isCompact)
    }

    private var horizontalPadding: CGFloat {
        Self.horizontalPadding(isCompact: isCompact)
    }

    private static func fontSize(isCompact: Bool) -> LimpidFont.Supervision.Size {
        isCompact ? .row : LimpidLayout.Supervision.segmentedFontSize
    }

    private static func horizontalPadding(isCompact: Bool) -> CGFloat {
        isCompact ? LimpidLayout.Supervision.spaceS : LimpidLayout.Supervision.segmentedHorizontalPadding
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LimpidLayout.Supervision.segmentedPillCornerRadius, style: .continuous)
    }

    var body: some View {
        let metrics = LimpidLayout.Supervision.self
        SupervisionSegmentedTrack(
            count: options.count,
            selectedIndex: options.firstIndex { $0.value == selection }
        ) { index in
            segment(at: index)
        } selectedLabel: { index, color in
            selectedLabel(at: index, color: color)
        }
        .opacity(isEnabled ? 1 : metrics.sheetFieldDisabledOpacity)
        // One stop for the keyboard, as a native segmented control is,
        // taken only when the person moves focus with the keyboard; the
        // arrows then move the selection.
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .supervisionFocusRing(
            isFocused: isFocused && isEnabled,
            cornerRadius: metrics.segmentedCornerRadius
        )
        .onKeyPress(.leftArrow) { press(by: -1) }
        .onKeyPress(.rightArrow) { press(by: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// Draws a label again, laid out as its segment is, in the pill's label
    /// color and a heavier weight: a second cue beside the fill for which
    /// segment is chosen. Only the pill's area of it shows.
    private func selectedLabel(at index: Int, color: Color) -> some View {
        let metrics = LimpidLayout.Supervision.self
        return label(of: options[index], weight: .semibold, color: color, dotColor: color)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: metrics.segmentedHeight - metrics.segmentedInset * 2)
    }

    /// A segment's words, and its dot when it has one, centered on the
    /// words' line: in the text color and the unread blue on the track,
    /// and both in the pill's label color under the pill, where the blue
    /// would stand on the accent.
    private func label(of option: Option, weight: Font.Weight, color: Color, dotColor: Color) -> some View {
        HStack(spacing: LimpidLayout.Supervision.segmentedDotSpacing) {
            option.title
                .font(.supervision(fontSize, weight: weight))
                .foregroundStyle(color)
                .lineLimit(1)
            if option.hasDot {
                Circle()
                    .fill(dotColor)
                    .frame(width: LimpidLayout.Supervision.segmentedDotSize, height: LimpidLayout.Supervision.segmentedDotSize)
                    .accessibilityHidden(true)
            }
        }
    }

    private func segment(at index: Int) -> some View {
        let option = options[index]
        let isSelected = option.value == selection
        let metrics = LimpidLayout.Supervision.self
        return Button {
            selection = option.value
        } label: {
            label(of: option, weight: .medium, color: SupervisionTokens.text.color, dotColor: SupervisionTokens.unread.color)
                .opacity(option.isEnabled ? 1 : metrics.sheetFieldDisabledOpacity)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity)
                .frame(height: metrics.segmentedHeight - metrics.segmentedInset * 2)
                .background(
                    pillShape.fill(
                        !isSelected && hoveredIndex == index && isEnabled && option.isEnabled ? SupervisionTokens.segmentHover
                            .color : .clear
                    )
                )
                .contentShape(pillShape)
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        // The control is the keyboard's one stop; its segments are not.
        .focusable(false)
        .onHover { isHovering in
            if isHovering {
                hoveredIndex = index
            } else if hoveredIndex == index {
                hoveredIndex = nil
            }
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(option.help ?? Text(verbatim: ""))
        .accessibilityValue(option.accessibilityValue ?? Text(verbatim: ""))
    }

    /// The narrowest the control can be with every segment's words whole,
    /// given each one's width as drawn under the pill (the heavier weight):
    /// the segments share the track equally, so the widest words decide
    /// every segment. A form that holds the control gives it at least this
    /// much (`NewSessionSheetLayoutTests`), since a segment cuts its words
    /// short rather than grow.
    static func minimumWidth(fittingLabelWidths widths: [CGFloat], isCompact: Bool = false) -> CGFloat {
        let widest = widths.max() ?? 0
        return CGFloat(widths.count) * (widest + horizontalPadding(isCompact: isCompact) * 2)
            + LimpidLayout.Supervision.segmentedInset * 2
    }

    /// The words of a segment as the pill draws them, the widest they are
    /// drawn, for a caller that measures them against the room it gives.
    static func labelFont(isCompact: Bool = false) -> Font {
        .supervision(fontSize(isCompact: isCompact), weight: .semibold)
    }

    private func press(by offset: Int) -> KeyPress.Result {
        let current = options.firstIndex { $0.value == selection }
        let enabled = options.map(\.isEnabled)
        let step = Self.keyStep(from: current, by: offset, count: options.count, isEnabled: isEnabled) { enabled[$0] }
        if let next = step.next {
            selection = options[next].value
        }
        return step.isHandled ? .handled : .ignored
    }

    /// What an arrow does from the segment at `index`. It moves one
    /// segment and stops at either end, as a native segmented control's
    /// does, keeping the key there so the focus does not leave. A segment
    /// that takes no choice is passed over, to the next one that does. A
    /// disabled control, or one whose selection is none of its segments,
    /// lets the key go on.
    nonisolated static func keyStep(
        from index: Int?,
        by offset: Int,
        count: Int,
        isEnabled: Bool,
        isSegmentEnabled: (Int) -> Bool = { _ in true }
    ) -> KeyStep {
        guard isEnabled, let index else { return KeyStep(next: nil, isHandled: false) }
        let direction = offset.signum()
        var next = index + offset
        while direction != 0, (0..<count).contains(next), !isSegmentEnabled(next) {
            next += direction
        }
        return KeyStep(next: (0..<count).contains(next) ? next : nil, isHandled: true)
    }
}

/// Where a segmented control's pill is over time, in segments from the
/// leading edge: from `from` at `start` to `to` after `duration`, eased in
/// and out, never past either end. A value, so a test reads every frame of
/// a slide without a window.
struct SegmentPillSlide: Equatable, Sendable {
    var from: Double
    var to: Double
    var start: Date
    /// Zero for a pill at rest.
    var duration: TimeInterval

    /// The pill at rest on the segment at `index`.
    static func resting(at index: Int) -> Self {
        SegmentPillSlide(from: Double(index), to: Double(index), start: .distantPast, duration: 0)
    }

    /// One segment's width, which is the pill's, for a track of
    /// `trackWidth` split among `count` segments.
    static func segmentWidth(trackWidth: CGFloat, count: Int) -> CGFloat {
        trackWidth / CGFloat(max(count, 1))
    }

    /// The slide a change of the selection starts. Only a change to
    /// another segment moves the pill: the same segment again, or a value
    /// that is none of them, leaves the pill as it is. A slide starts from
    /// wherever the pill is now, so a second click mid-slide turns it
    /// without a jump. With Reduce Motion it is shorter, but still a
    /// slide: with no movement at all the control reads as one that did
    /// not take the click, as `LimpidMotion.reducedSlide` says.
    static func after(
        selecting new: Int?,
        previously old: Int?,
        current: Self,
        now: Date,
        reduceMotion: Bool
    ) -> Self {
        guard let new, new != old else { return current }
        let duration = reduceMotion ? LimpidMotion.reducedSegmentSlideDuration : LimpidMotion.segmentSlideDuration
        return SegmentPillSlide(from: current.position(at: now), to: Double(new), start: now, duration: duration)
    }

    func position(at date: Date) -> Double {
        guard duration > 0 else { return to }
        let progress = min(max(date.timeIntervalSince(start) / duration, 0), 1)
        return from + (to - from) * Self.easeInOut(progress)
    }

    /// A cubic ease in and out of `progress` in 0...1: it starts and ends
    /// still and stays within 0...1, so the pill never passes its segment.
    static func easeInOut(_ progress: Double) -> Double {
        progress < 0.5
            ? 4 * progress * progress * progress
            : 1 - pow(-2 * progress + 2, 3) / 2
    }
}
