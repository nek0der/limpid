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
//   3. `.navigationTitle(...)` — Apple's panes self-identify in the
//      window title bar; we mirror that so the user can read where
//      they are without an inline H1.
//
// Slider rows go through `SliderRow` so spacing + monospaced value
// labels stay identical across panes. System Settings's own sliders
// (Display brightness, Sound volume) place the value text trailing
// in a fixed-width mono slot — that's what we reproduce.

import SwiftUI

struct SettingsForm<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        // Detail pane fills the whole window as `SettingsScene`'s
        // background plane, so we offset content right of the
        // floating sidebar slab (`SettingsScene.leadingInset`).
        // Top spacer matches the slab's traffic-light reservation
        // so the title baseline aligns with the first sidebar row.
        HStack(spacing: 0) {
            Spacer().frame(width: SettingsScene.leadingInset)
            VStack(alignment: .leading, spacing: 0) {
                // Title sits on the same y as the traffic-light row
                // (which `repositionTrafficLights` parks at y≈22).
                // 12pt top padding lands the title baseline next to
                // the triad — same affordance the main window's
                // toolbar shows on its container slab.
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Form { content }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .controlSize(.regular)
            }
        }
    }
}

/// `LabeledContent` + Slider + mono-digit trailing value. Apple's
/// own sliders sit inside the `LabeledContent` value slot (no extra
/// HStack), but they always include a fixed-width value readout —
/// we follow the same shape.
struct SliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    /// Optional discrete step. Omit (or pass `nil`) for a continuous
    /// slider — Apple's System Settings uses continuous sliders for
    /// brightness / opacity / volume; explicit ticks are reserved
    /// for things like keyboard repeat rate where every position
    /// snaps to a named value.
    var step: Double?
    var format: (Double) -> String = { "\(Int($0 * 100))%" }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
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

    var body: some View {
        let doubleBinding = Binding<Double>(
            get: { Double(value) },
            set: { value = Int($0) }
        )
        LabeledContent {
            HStack(spacing: 8) {
                Slider(
                    value: doubleBinding,
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: Double(step)
                )
                Text("\(value)\(suffix.isEmpty ? "" : " \(suffix)")")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}
