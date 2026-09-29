// SettingsForm.swift
// Limpid — wrapper that pins every Settings pane to macOS 26 System
// Settings shape. Three things matter for the look:
//
//   1. `.formStyle(.grouped)` — inset-grouped form with the auto
//      ~600pt content cap. This is what produces the System
//      Settings "card" rhythm. We do NOT add `.frame(maxWidth:)`
//      because that would override the cap and let rows stretch
//      across a wide window.
//   2. `.scrollContentBackground(.hidden)` — Settings is hosted by
//      Limpid's tuned toolbar, so the form must not paint its own
//      backdrop on top.
//   3. The pane title is drawn in a `safeAreaBar` over the form,
//      beside the traffic lights, so rows scroll under it.
//
// Slider rows go through `SliderRow` so spacing + monospaced value
// labels stay identical across panes. System Settings's own sliders
// (Display brightness, Sound volume) place the value text trailing
// in a fixed-width mono slot — that's what we reproduce.

import SwiftUI

struct SettingsForm<Content: View>: View {
    let title: LocalizedStringKey
    let section: SettingsSection
    @ViewBuilder var content: Content

    @Environment(\.settingsRevealRequest) private var revealRequest
    @Environment(\.accessibilityReduceMotion) private var shouldReduceMotion
    @State private var highlightedEntryID: String?

    var body: some View {
        // Detail pane fills the whole window as `SettingsScene`'s
        // background plane, so we offset content right of the sidebar
        // (`SettingsScene.sidebarWidth`). What lines the title up
        // with the traffic-light row is the title's own top padding
        // below, not a spacer here.
        HStack(spacing: 0) {
            Spacer().frame(width: SettingsScene.sidebarWidth)
            ScrollViewReader { proxy in
                Form { content }
                    .contentMargins(.leading, SettingsScene.detailGutter, for: .scrollContent)
                    // The title is a bar over the form rather than a view
                    // stacked above it, so scrolled rows pass under it
                    // behind the scroll edge effect instead of being cut
                    // off flush against the title's baseline.
                    .safeAreaBar(edge: .top) {
                        // Title sits beside the traffic-light row, which
                        // `repositionTrafficLights` centers on the strip's
                        // midline (window-y 26, buttons spanning 19–33).
                        // The padding lands the title next to the triad —
                        // same affordance the main window's toolbar shows
                        // on its container sidebar.
                        Text(title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .padding(.leading, 20 + SettingsScene.detailGutter)
                            .padding(.trailing, 20)
                            // Same space below as above, so the title sits
                            // centered in the bar the rows scroll under.
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .controlSize(.regular)
                    // The window propagates the user's accent as
                    // `.tint`, which on macOS 26 also colors pop-up
                    // values and bordered button labels. System
                    // Settings keeps those neutral and reserves the
                    // accent for switches and sliders, so the form
                    // drops the tint here; `SettingsToggle`, the slider
                    // rows, and the update view's default button put it
                    // back.
                    .tint(nil as Color?)
                    .environment(\.settingsHighlightedEntryID, highlightedEntryID)
                    .task(id: revealRequest?.sequence) {
                        highlightedEntryID = nil
                        guard let request = revealRequest,
                              request.section == section
                        else { return }
                        // The task starts after this pane is mounted. Yield
                        // once so Form has published its row identities.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        if shouldReduceMotion {
                            proxy.scrollTo(request.entryID, anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                proxy.scrollTo(request.entryID, anchor: .center)
                            }
                        }
                        highlightedEntryID = request.entryID
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled,
                              revealRequest?.sequence == request.sequence
                        else { return }
                        highlightedEntryID = nil
                    }
            }
        }
    }
}

/// Slider + mono-digit trailing value, laid out as a `settingsControlRow`.
/// The slider has a fixed width and the readout a fixed slot so the
/// track's edges line up across rows regardless of label width. The
/// row is an `HStack` rather than `LabeledContent`, so the slider does
/// not pick up the label for accessibility on its own; we set it. In a
/// `Form` the slider also reserves an empty label column inside its
/// frame; `labelsHidden()` removes it so the track fills the frame.
struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    @Environment(\.limpidAccent) private var accent
    var range: ClosedRange<Double> = 0...1
    /// Optional discrete step. Omit (or pass `nil`) for a continuous
    /// slider — Apple's System Settings uses continuous sliders for
    /// brightness / opacity / volume; explicit ticks are reserved
    /// for things like keyboard repeat rate where every position
    /// snaps to a named value.
    var step: Double?
    var format: (Double) -> String = { "\(Int($0 * 100))%" }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Group {
                    if let step {
                        Slider(value: $value, in: range, step: step)
                    } else {
                        Slider(value: $value, in: range)
                    }
                }
                .tint(accent)
                .labelsHidden()
                .frame(width: LimpidLayout.settingsSliderWidth)
                .accessibilityLabel(Text(title))
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: LimpidLayout.settingsSliderValueWidth, alignment: .trailing)
            }
        }
        .settingsControlRow(controlHeight: LimpidLayout.settingsSliderControlHeight)
    }
}

/// Integer-valued variant for font size, line height, etc. Uses
/// the same shape as `SliderRow`.
struct SliderRowInt: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int = 1
    var suffix: String = ""
    @Environment(\.limpidAccent) private var accent

    var body: some View {
        let doubleBinding = Binding<Double>(
            get: { Double(value) },
            set: { value = Int($0) }
        )
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Slider(
                    value: doubleBinding,
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: Double(step)
                )
                .tint(accent)
                .labelsHidden()
                .frame(width: LimpidLayout.settingsSliderWidth)
                .accessibilityLabel(Text(title))
                Text("\(value)\(suffix.isEmpty ? "" : " \(suffix)")")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: LimpidLayout.settingsSliderValueWidth, alignment: .trailing)
            }
        }
        .settingsControlRow(controlHeight: LimpidLayout.settingsSliderControlHeight)
    }
}

/// A switch row for Settings: the form's own switch row, tinted with
/// Limpid's accent and nudged so the switch sits centered.
///
/// The `Toggle` stays a direct row of the `Form` on purpose. Laid out
/// that way the form uses the AppKit switch (`AXSwitch`, which
/// VoiceOver and `AXPress` can flip); inside an `HStack` or a custom
/// `ToggleStyle` SwiftUI draws its own switch, which accessibility
/// reports as a toggle without a press action. The form places that
/// row's content 4pt high on macOS 26 (measured), so the padding moves
/// it down and gives back the height.
///
/// The label does not dim with `.disabled` on its own (the switch
/// does), so the foreground style follows `isEnabled` the way an
/// AppKit control's title would.
struct SettingsToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    @Environment(\.limpidAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .tint(accent)
            .foregroundStyle(isEnabled ? Color.primary : Color(nsColor: .disabledControlTextColor))
            .padding(.top, 1.5)
            .padding(.bottom, -2.5)
    }
}

extension View {
    /// Lays out a custom `HStack` row (label, spacer, control) like the
    /// form's native control rows, with the control centered.
    /// `controlHeight` is the tallest control in the row; pop-ups,
    /// steppers, and bordered buttons are 24pt. See
    /// `LimpidLayout.settingsRowContentHeight` for the model.
    func settingsControlRow(controlHeight: CGFloat = 24) -> some View {
        padding(.vertical, -(controlHeight - LimpidLayout.settingsRowContentHeight) / 2)
    }
}
