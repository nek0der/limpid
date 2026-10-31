// SettingsForm.swift
// Weir — wrapper that pins every Settings pane to macOS 26 System
// Settings shape. Three things matter for the look:
//
//   1. `.formStyle(.grouped)` — inset-grouped form with the auto
//      ~600pt content cap. This is what produces the System
//      Settings "card" rhythm. We do NOT add `.frame(maxWidth:)`
//      because that would override the cap and let rows stretch
//      across a wide window.
//   2. `.scrollContentBackground(.hidden)` — Settings is hosted by
//      Weir's tuned toolbar, so the form must not paint its own
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
                            withAnimation(WeirMotion.revealScroll) {
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
    let title: LocalizedStringResource
    @Binding var value: Double
    @Environment(\.weirAccent) private var accent
    var range: ClosedRange<Double> = 0...1
    /// Optional discrete step. Omit (or pass `nil`) for a continuous
    /// slider — Apple's System Settings uses continuous sliders for
    /// brightness / opacity / volume; explicit ticks are reserved
    /// for things like keyboard repeat rate where every position
    /// snaps to a named value.
    var step: Double?
    var format: (Double) -> String = { "\(Int($0 * 100))%" }
    /// The value "Restore Default" brings back, offered while the slider is
    /// away from it by more than its readout shows; nil for none.
    var defaultValue: Double?

    var body: some View {
        HStack(spacing: 12) {
            SettingsValueRowTitle(title: title)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if let defaultValue {
                    RestoreDefaultSlot(
                        title: title,
                        // Half a percent: what the readout rounds away.
                        isShown: RestoreDefaultSlot.isShown(value: value, defaultValue: defaultValue, tolerance: 0.005)
                    ) {
                        value = defaultValue
                    }
                }
                Group {
                    if let step {
                        Slider(value: $value, in: range, step: step)
                    } else {
                        Slider(value: $value, in: range)
                    }
                }
                .tint(accent)
                .labelsHidden()
                .frame(width: WeirLayout.settingsSliderWidth)
                .accessibilityLabel(Text(title))
                // The value as the row shows it: on its own the slider reads
                // how far along its range it is, which for 0.5–1.0 is not
                // the opacity on screen.
                .accessibilityValue(Text(verbatim: format(value)))
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(SettingsFootnote.style.color)
                    .frame(width: WeirLayout.settingsSliderValueWidth, alignment: .trailing)
            }
            // A container, so the ↺'s sort priority orders it after the
            // slider (`RestoreDefaultSlot`).
            .accessibilityElement(children: .contain)
        }
        .settingsControlRow(controlHeight: WeirLayout.settingsSliderControlHeight)
    }
}

/// The label of a value row (`SliderRow`, `SettingsNumberRow`): it yields
/// its width to the controls. A grouped form lays a row whose content
/// asks for more width than the row has out as a stack, the label over the
/// controls in a row twice as tall; a value row's controls with their
/// restore slot already take most of the row, so a label a
/// little longer ("Unfocused pane opacity", and its Japanese) had the
/// whole row stacked, which read as a tall box with a gap above the
/// slider. With the lowest layout priority the label is the part that
/// gives way, so the row is laid out as a row whatever the label says
/// (measured on macOS 26: the priority alone does it, where a frame with
/// no ideal width stacked the row still). A label longer than the width
/// left wraps to a second line, as System Settings wraps its own, and only
/// past that is cut at its end and read whole in its tooltip.
struct SettingsValueRowTitle: View {
    let title: LocalizedStringResource
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(title)
            .foregroundStyle(isEnabled ? Color.primary : Color(nsColor: .disabledControlTextColor))
            .lineLimit(2)
            .truncationMode(.tail)
            .layoutPriority(-1)
            .help(Text(title))
    }
}

/// A number the person knows, typed or stepped: a field and a stepper side
/// by side, with the unit after the field, as macOS lays out a value with a
/// range. A slider is for a value found by looking (the opacities); this is
/// for one decided beforehand (13 pt, 30 days). What is typed is held to
/// the range when the field commits, on Return or when it loses focus.
struct SettingsNumberRow: View {
    let title: LocalizedStringResource
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// The unit after the field ("days", "pt"), or nil for none.
    var unit: LocalizedStringResource?
    /// What a 0 means, shown before the field ("Default") when the value
    /// is 0 and 0 stands for "no setting of its own".
    var zeroMeaning: LocalizedStringResource?
    /// The value "Restore Default" brings back, offered while the row holds
    /// another; nil for none. Set through `value`, so a row whose
    /// binding asks before it saves (the turn history's) asks for this too.
    var defaultValue: Double?

    private var format: FloatingPointFormatStyle<Double> {
        // A whole step shows whole numbers; a half step, one decimal.
        .number.precision(.fractionLength(step.rounded() == step ? 0...0 : 0...1)).grouping(.never)
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsValueRowTitle(title: title)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if let defaultValue {
                    RestoreDefaultSlot(
                        title: title,
                        isShown: RestoreDefaultSlot.isShown(value: value, defaultValue: defaultValue)
                    ) {
                        value = defaultValue
                    }
                }
                if let zeroMeaning, value == 0 {
                    Text(zeroMeaning)
                        .foregroundStyle(SettingsFootnote.style.color)
                }
                TextField(
                    "",
                    value: Binding(get: { value }, set: { value = Self.held($0, to: range, step: step) }),
                    format: format
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: WeirLayout.settingsSliderValueWidth)
                .accessibilityLabel(Text(title))
                .help(Text(LocalizedStringResource(
                    // A range is a wave dash in Japanese and an en dash in English.
                    "settings.rangeTooltip",
                    defaultValue: "\(range.lowerBound.formatted(format))–\(range.upperBound.formatted(format))",
                    comment: "Settings: tooltip of a number field; its lowest and highest values, already formatted"
                )))
                if let unit {
                    Text(unit)
                        .foregroundStyle(SettingsFootnote.style.color)
                }
                Stepper(value: $value, in: range, step: step) {
                    Text(title)
                }
                .labelsHidden()
                .accessibilityLabel(Text(title))
            }
            // A container, so the ↺'s sort priority orders it after the
            // field and the stepper (`RestoreDefaultSlot`).
            .accessibilityElement(children: .contain)
        }
        .settingsStepperRow()
    }

    /// `typed` held to `range` and to the step's grid, so a field cannot
    /// save what the stepper could never reach.
    nonisolated static func held(_ typed: Double, to range: ClosedRange<Double>, step: Double) -> Double {
        let snapped = step > 0 ? (typed / step).rounded() * step : typed
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

extension Binding where Value == Double {
    /// An integer setting as the `Double` a `SettingsNumberRow` edits.
    init(integer: Binding<Int>) {
        self.init(get: { Double(integer.wrappedValue) }, set: { integer.wrappedValue = Int($0.rounded()) })
    }
}

/// A switch row for Settings: the form's own switch row at the mini size,
/// tinted with Weir's accent and held to the pop-up rows' height.
///
/// Mini is the switch System Settings puts in a grouped form's rows (36 by
/// 16, measured on macOS 26), and the one the HIG names for a setting in a
/// single row of a grouped form. The regular switch the form picks on its
/// own is 54 by 24, half again as wide, and stood out beside the pop-ups.
///
/// The `Toggle` stays a direct row of the `Form` on purpose. Laid out
/// that way the form uses the AppKit switch (`AXSwitch`, which
/// VoiceOver and `AXPress` can flip); inside an `HStack` or a custom
/// `ToggleStyle` SwiftUI draws its own switch, which accessibility
/// reports as a toggle without a press action. The form gives a mini
/// switch row 4pt more than a pop-up row (measured on macOS 26), with the
/// switch 2pt below its label's middle. The padding takes the 4pt back
/// (`SettingsRowMetricsTests`), most of it from above, so the switch sits
/// on the row's middle the way a pop-up does. Taken evenly, the switch
/// sat 1.5pt low, which read as off center next to the pop-up rows. The
/// label then sits 2pt above the middle, so it moves down by 1.5pt to sit
/// where the pop-up rows' labels do. Only its drawing moves; its frame,
/// and so what VoiceOver outlines, stays where the form put it.
///
/// The label does not dim with `.disabled` on its own (the switch
/// does), so the foreground style follows `isEnabled` the way an
/// AppKit control's title would.
struct SettingsToggle: View {
    let title: Text
    @Binding var isOn: Bool
    @Environment(\.weirAccent) private var accent
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = Text(title)
        self._isOn = isOn
    }

    /// For a label made at run time (the project settings' agent rows).
    init(_ title: Text, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { title.offset(y: 1.5) }
            .controlSize(.mini)
            .tint(accent)
            .foregroundStyle(isEnabled ? Color.primary : Color(nsColor: .disabledControlTextColor))
            .padding(.top, -3)
            .padding(.bottom, -1)
    }
}

/// A section's caption: the words under a group (its `footer:`) or under a
/// row that explains it. Its `style` is also the color of the settings
/// window's other quiet words: a row's value, a search result's group.
///
/// The grounds below are the settings window's glass as measured on
/// macOS 26 beside the footers, and the opaque window background that
/// Reduce Transparency swaps in. On the light glass (#E8E8E8) a grouped
/// form's own footer gray (#7A7879) is 3.6:1, short of the 4.5:1 we ask
/// of text. Weir's captions are long and meant to be read, so they take
/// the supervision window's quiet text instead: `muted` is 4.8:1 on that
/// glass and above 4.5:1 on the opaque background in either appearance
/// (`SupervisionTokensTests`). On the dark glass (about #3A3A3A) it is
/// 4.3:1, short of 4.5:1: the glass takes its tone from the wallpaper
/// behind the window, so no fixed value holds there, and we keep the one
/// quiet color the supervision window uses rather than tune one for a
/// ground that moves. The form keeps choosing the size; only the color is
/// ours.
struct SettingsFootnote: View {
    /// The color every caption is drawn in, named so the contrast test
    /// checks what the view draws.
    nonisolated static let style = SupervisionTokens.muted

    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .foregroundStyle(Self.style.color)
    }
}

extension View {
    /// Lays out a custom `HStack` row (label, spacer, control) like the
    /// form's native control rows, with the control centered.
    /// `controlHeight` is the tallest control in the row; pop-ups and
    /// bordered buttons are 24pt, and a row with a stepper uses
    /// `settingsStepperRow`. See `WeirLayout.settingsRowContentHeight`
    /// for the model.
    func settingsControlRow(controlHeight: CGFloat = 24) -> some View {
        padding(.vertical, -(controlHeight - WeirLayout.settingsRowContentHeight) / 2)
    }

    /// `settingsControlRow` for a row whose tallest control is a stepper.
    /// AppKit's regular stepper is 24pt tall on macOS 27 and 26pt on
    /// macOS 26, so we read its height rather than write one down: a fixed
    /// 24 left a number row 2.5pt taller than a pop-up row on macOS 26.
    func settingsStepperRow() -> some View {
        settingsControlRow(controlHeight: SettingsStepperMetrics.size.height)
    }
}

/// The regular stepper as this macOS draws it, which the rows that hold
/// one are sized from (`settingsStepperRow`).
@MainActor
enum SettingsStepperMetrics {
    static let size: CGSize = {
        let stepper = NSStepper()
        stepper.controlSize = .regular
        return stepper.fittingSize
    }()
}

/// A row of buttons with no label of its own, held to the trailing edge
/// where every other row keeps its control. A button placed directly in
/// the form sits at the leading edge instead, where a label would be, and
/// gets a taller row than the pop-up rows (44pt against 38pt, measured on
/// macOS 26); as a custom row `settingsControlRow` sizes it.
struct SettingsButtonRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content
        }
        .settingsControlRow()
    }
}

/// What a setting that only applies at launch shows once it is waiting for
/// one: why, and "Relaunch", which quits through the usual confirmation and
/// opens Weir again (`AppRelaunch`). A note that only told the person to
/// restart left them to find the way.
struct RelaunchRow: View {
    let reason: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            SettingsFootnote(reason)
            Spacer(minLength: 12)
            Button("Relaunch") {
                AppRelaunch.relaunch()
            }
            .help(Text("Quits and reopens Weir."))
        }
        .settingsControlRow()
    }
}

/// How a pop-up shows which of its items is the default: "(Default)" after
/// its words, as macOS marks one. With `RestoreDefaultButton` it is the
/// one way Settings says what the default is: a pop-up names it in its
/// items, and a value that is not a pop-up offers "Restore Default".
enum SettingsDefaultMark {
    static func title(_ text: Text, isDefault: Bool) -> Text {
        isDefault ? Text("\(text) (Default)") : text
    }

    /// `text` for the item that sets `value`, marked when `value` is what a
    /// fresh `WeirSettings` holds at `setting`, so the mark follows the
    /// model's default rather than a copy of it in the view.
    static func title<Value: Equatable>(
        _ text: Text,
        value: Value,
        of setting: KeyPath<WeirSettings, Value>
    ) -> Text {
        title(text, isDefault: WeirSettings.default[keyPath: setting] == value)
    }
}

/// How a list or a text block goes back to its default: a borderless
/// "Restore Default" at the trailing end of the setting's bar, shown only
/// while the value differs from the default. A value row has its glyph
/// form, `RestoreDefaultSlot`, before its controls; under a block there is
/// room for the words.
struct RestoreDefaultButton: View {
    /// What VoiceOver and the tooltip name the button when the row's label
    /// does not say which setting it restores; nil reads the title.
    var accessibilityLabel: LocalizedStringResource?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Restore Default")
        }
        .buttonStyle(.borderless)
        .help(Text(accessibilityLabel ?? LocalizedStringResource("Restore Default")))
        .accessibilityLabel(Text(accessibilityLabel ?? LocalizedStringResource("Restore Default")))
    }
}

/// The ↺ of a value row, placed before the row's controls: a ↺
/// while the value is not its default, and the same room, empty, while it
/// is, so the controls stay where they are as the button comes and goes.
/// Before the controls rather than after them, as the shortcut rows place
/// theirs, so a value row's last control ends at the edge every switch and
/// pop-up ends at; after them, the empty room on a row at its default left
/// the stepper short of that edge by the slot's width. It is the glyph the
/// shortcut rows use rather than the words: the words took a hundred points
/// of every value row, wrapped the longer labels, and left a gap as wide on
/// each row still at its default.
struct RestoreDefaultSlot: View {
    /// What the row sets, which the button's VoiceOver name and tooltip
    /// say it restores.
    let title: LocalizedStringResource
    let isShown: Bool
    let action: () -> Void

    /// Whether a row showing `value` offers its default back: one away from
    /// `defaultValue` by more than `tolerance` (a slider's readout rounds,
    /// so a hair away reads as the default). None for a row with no
    /// default of its own.
    nonisolated static func isShown(value: Double, defaultValue: Double?, tolerance: Double = 0) -> Bool {
        guard let defaultValue else { return false }
        return abs(value - defaultValue) > tolerance
    }

    /// "Restore Default Size": a pane has several of these buttons, and
    /// each says whose default it brings back.
    static func label(for title: LocalizedStringResource) -> LocalizedStringResource {
        LocalizedStringResource(
            "settings.restoreDefaultOf",
            defaultValue: "Restore Default \(title)",
            comment: "Settings: VoiceOver name and tooltip of a value row's Restore Default; argument: the row's label"
        )
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .help(Text(Self.label(for: title)))
        .accessibilityLabel(Text(Self.label(for: title)))
        .frame(width: WeirLayout.settingsRecorderAccessoryWidth, alignment: .center)
        .opacity(isShown ? 1 : 0)
        .disabled(!isShown)
        .accessibilityHidden(!isShown)
        // Drawn before the controls, read after them: VoiceOver gives the
        // value first and then the way back to the default, rather than
        // landing on "Restore Default" before the person has heard what the
        // row holds. The row's controls sit in a container for this.
        .accessibilitySortPriority(-1)
    }
}
