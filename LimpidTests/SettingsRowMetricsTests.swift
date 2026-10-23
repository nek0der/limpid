// SettingsRowMetricsTests.swift
// Limpid — the settings rows' measures against a grouped form's own: where controls end, how big they are, how tall rows are.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

/// System Settings on macOS 26 (Accessibility > Switch Control, measured
/// through the accessibility tree) ends every row's control at one edge, 10pt
/// in from the card; draws its switches 36 by 16, the mini switch, and its
/// pop-ups and steppers 24pt tall, the regular ones; and steps its rows about
/// 38pt apart. These hold Limpid's rows to the same, beside a native grouped
/// form's rows hosted next to them.
@MainActor
struct SettingsRowMetricsTests {
    /// A switch row, a value row at its default (the ↺'s room empty), one
    /// away from it (the ↺ shown), and one with "Default" before its field
    /// all end where the form ends a native control. A ↺ placed after the
    /// stepper would leave a number row 24pt short of that edge (a slider
    /// row 26pt). The slider row is not among these: SwiftUI draws its
    /// slider and readout without an AppKit view to measure.
    @Test func everyRowKind_endsAtTheFormsTrailingEdge() async throws {
        let form = SettingsForm(title: "Probe", section: .font) {
            Section {
                Toggle("Native", isOn: .constant(true))
                    .toggleStyle(.switch)
                SettingsToggle("Ligatures", isOn: .constant(true))
                SettingsNumberRow(title: "Size", value: .constant(13), range: 6...72, unit: "pt", defaultValue: 13)
                SettingsNumberRow(title: "Size", value: .constant(15), range: 6...72, unit: "pt", defaultValue: 13)
                SettingsNumberRow(
                    title: "Line spacing",
                    value: .constant(0),
                    range: -4...10,
                    unit: "px",
                    zeroMeaning: "Default",
                    defaultValue: 0
                )
            }
        }
        let (window, host) = hostedInWindow(form, width: SettingsScene.windowWidth, height: 600)
        defer { window.close() }
        let edges = try #require(await Self.trailingEdges(in: host, switches: 2, steppers: 3))
        // The native switch, which the form places itself, is the edge.
        let edge = try #require(edges.switches.max())
        for maxX in edges.switches + edges.steppers {
            #expect(abs(maxX - edge) <= 0.5, "a control ends at \(maxX), the form's edge is \(edge)")
        }
    }

    /// Tabs & Panes lays its minimum pane size out by hand, a readout
    /// rather than a field before the stepper: its stepper, ↺ shown or not,
    /// ends where the pane's switch does.
    @Test(arguments: [TerminalSettings.defaultMinPaneSize, TerminalSettings.defaultMinPaneSize + 40])
    func theMinimumPaneSizeRow_endsWhereTheSwitchDoes(minPaneSize: Double) async throws {
        try await withTempDir { directory in
            let store = SettingsStore(directory: directory, writesFiles: false)
            store.settings.terminal.minPaneSize = minPaneSize
            let pane = TabsAndPanesPane()
                .environment(store)
                .environment(ReduceTransparencyResolver())
            let (window, host) = hostedInWindow(pane, width: SettingsScene.windowWidth, height: 900)
            defer { window.close() }
            let edges = try #require(await Self.trailingEdges(in: host, switches: 1, steppers: 1))
            let edge = try #require(edges.switches.first)
            let stepper = try #require(edges.steppers.first)
            #expect(abs(stepper - edge) <= 0.5, "the stepper ends at \(stepper), the switch at \(edge)")
        }
    }

    /// The ↺ is before the row's controls, left of the field and the
    /// stepper; that it leaves the stepper where it was while hidden is the
    /// edge test above, which has the row both ways.
    @Test func aValueRowsRestoreButton_sitsBeforeItsControls() async throws {
        let form = SettingsForm(title: "Probe", section: .font) {
            Section {
                SettingsNumberRow(title: "Size", value: .constant(15), range: 6...72, unit: "pt", defaultValue: 13)
            }
        }
        let (window, host) = hostedInWindow(form, width: SettingsScene.windowWidth, height: 400)
        defer { window.close() }
        let frames = await settledValue(in: host) { () -> [CGRect]? in
            // The row's one control besides its field and stepper. SwiftUI
            // keeps the button's VoiceOver name on its own element, not on
            // the AppKit button, so the name cannot find it.
            let restore = Self.views(NSControl.self, in: host).first {
                !($0 is NSSwitch || $0 is NSStepper || $0 is NSTextField)
            }
            guard let restore,
                  let field = Self.views(NSTextField.self, in: host).first,
                  let stepper = Self.views(NSStepper.self, in: host).first
            else { return nil }
            return [restore, field, stepper].map { Self.frame(of: $0, in: host) }
        }
        let laidOut = try #require(frames, "the ↺, the field, and the stepper")
        #expect(laidOut[0].maxX <= laidOut[1].minX)
        #expect(laidOut[0].maxX <= laidOut[2].minX)
    }

    /// The switch is the mini one System Settings draws in a form's rows,
    /// not the regular one the form picks on its own (54 by 24); the stepper
    /// stays the regular one System Settings also uses, at AppKit's own size
    /// for it (20 by 24 on macOS 27, 20 by 26 on macOS 26).
    @Test func theControls_areTheSizesSystemSettingsUses() async throws {
        let form = SettingsForm(title: "Probe", section: .font) {
            Section {
                SettingsToggle("Ligatures", isOn: .constant(true))
                SettingsNumberRow(title: "Size", value: .constant(13), range: 6...72, unit: "pt", defaultValue: 13)
            }
        }
        let (window, host) = hostedInWindow(form, width: SettingsScene.windowWidth, height: 400)
        defer { window.close() }
        await settle(host) {
            !Self.views(NSSwitch.self, in: host).isEmpty && !Self.views(NSStepper.self, in: host).isEmpty
        }
        let toggle = try #require(Self.views(NSSwitch.self, in: host).first)
        let stepper = try #require(Self.views(NSStepper.self, in: host).first)
        // The switch is exact on purpose: a point release that resizes it
        // is the cue to measure System Settings again. The stepper's size
        // differs between macOS 26 and 27, so it is compared with AppKit's.
        #expect(toggle.controlSize == .mini)
        #expect(toggle.frame.size == CGSize(width: 36, height: 16))
        #expect(stepper.controlSize == .regular)
        let native = NSStepper()
        native.controlSize = .regular
        #expect(stepper.frame.size == native.fittingSize)
    }

    /// Each kind of row steps as far as a native pop-up row does, within
    /// the half point the form rounds a row by; a row half a point off
    /// makes a pane's rows uneven.
    @Test(arguments: RowKind.allCases)
    func everyRowKind_stepsLikeAPopUpRow(kind: RowKind) {
        let popUp = Self.pitch(of: .popUp)
        let row = Self.pitch(of: kind)
        #expect(abs(row - popUp) <= 0.5, "\(kind) rows step \(row), pop-up rows \(popUp)")
    }

    // MARK: - Helpers

    enum RowKind: CaseIterable, Sendable {
        case popUp, toggle, numberAtDefault, numberAway, slider, button
    }

    /// How far apart rows of one kind are: the height three of them add
    /// over one, halved, so the card's own insets fall out.
    private static func pitch(of kind: RowKind) -> CGFloat {
        let one = fittingHeight(of: RowsForm(kind: kind, count: 1))
        let three = fittingHeight(of: RowsForm(kind: kind, count: 3))
        return (three - one) / 2
    }

    private struct RowsForm: View {
        let kind: RowKind
        let count: Int

        var body: some View {
            Form {
                Section {
                    ForEach(0..<count, id: \.self) { _ in
                        row
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 600)
        }

        @ViewBuilder private var row: some View {
            switch kind {
            case .popUp:
                Picker("Family", selection: .constant(0)) {
                    Text(verbatim: "Default (JetBrains Mono)").tag(0)
                }
            case .toggle:
                SettingsToggle("Ligatures", isOn: .constant(true))
            case .numberAtDefault:
                SettingsNumberRow(title: "Size", value: .constant(13), range: 6...72, unit: "pt", defaultValue: 13)
            case .numberAway:
                SettingsNumberRow(title: "Size", value: .constant(15), range: 6...72, unit: "pt", defaultValue: 13)
            case .slider:
                SliderRow(title: "Opacity", value: .constant(0.5), defaultValue: 0.7)
            case .button:
                SettingsButtonRow {
                    Button("Relaunch") {}
                }
            }
        }
    }

    /// The trailing edges of the switches and steppers in `host` once
    /// there are as many as expected and two layouts in a row agree.
    private static func trailingEdges(
        in host: NSView,
        switches: Int,
        steppers: Int
    ) async -> (switches: [CGFloat], steppers: [CGFloat])? {
        let edges = await settledValue(in: host) { () -> [[CGFloat]]? in
            let found = (
                views(NSSwitch.self, in: host).map { frame(of: $0, in: host).maxX },
                views(NSStepper.self, in: host).map { frame(of: $0, in: host).maxX }
            )
            guard found.0.count == switches, found.1.count == steppers else { return nil }
            return [found.0, found.1]
        }
        guard let edges else { return nil }
        return (edges[0], edges[1])
    }

    private static func views<Found: NSView>(_ type: Found.Type, in host: NSView) -> [Found] {
        descendants(of: host).compactMap { $0 as? Found }
    }

    private static func frame(of view: NSView, in host: NSView) -> CGRect {
        view.convert(view.bounds, to: host)
    }
}
