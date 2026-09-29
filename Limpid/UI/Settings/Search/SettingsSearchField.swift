// SettingsSearchField.swift
// Limpid — Native macOS search input for the custom Settings sidebar.

import AppKit
import SwiftUI

struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt
    let onMoveSelection: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> SettingsSearchNSField {
        let field = SettingsSearchNSField()
        field.delegate = context.coordinator
        field.placeholderString = searchLabel
        field.setAccessibilityLabel(searchLabel)
        field.controlSize = .regular
        field.drawsBackground = false
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: SettingsSearchNSField, context: Context) {
        context.coordinator.parent = self
        let editor = field.currentEditor() as? NSTextView
        if editor?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = searchLabel
        field.setAccessibilityLabel(searchLabel)
        guard context.coordinator.appliedFocusRequest != focusRequest else { return }
        context.coordinator.appliedFocusRequest = focusRequest
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private var searchLabel: String {
        let resource: LocalizedStringResource = "Search Settings"
        return resource.settingsResolved(locale: locale)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SettingsSearchField
        var appliedFocusRequest: UInt

        init(_ parent: SettingsSearchField) {
            self.parent = parent
            self.appliedFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
            if field.stringValue.isEmpty {
                parent.onCancel()
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if !parent.text.isEmpty {
                    parent.text = ""
                    parent.onCancel()
                } else {
                    control.window?.makeFirstResponder(nil)
                }
                return true
            default:
                return false
            }
        }
    }
}

/// `NSSearchField` whose cell skips the bezel fill, so the translucent
/// capsule `SettingsSidebarSlab` paints behind it shows through. In this
/// non-vibrant host AppKit paints the bezel opaque (near-white in light
/// mode, near-black in dark mode) where System Settings shows a
/// translucent capsule. Turning the bezel off instead
/// (`isBezeled = false`) moved the field editor under the magnifier;
/// keeping the bezel and not painting it preserves the editor rect and
/// the capsule-shaped focus ring.
final class SettingsSearchNSField: NSSearchField {
    // `class` is required to override `NSControl.cellClass`.
    // swiftlint:disable:next static_over_final_class
    override class var cellClass: AnyClass? {
        get { SettingsSearchNSFieldCell.self }
        set {}
    }
}

private final class SettingsSearchNSFieldCell: NSSearchFieldCell {
    /// `draw(withFrame:in:)` paints the bezel and then the interior; we
    /// paint the interior and the two buttons only.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
        searchButtonCell?.draw(withFrame: searchButtonRect(forBounds: cellFrame), in: controlView)
        if !stringValue.isEmpty {
            cancelButtonCell?.draw(withFrame: cancelButtonRect(forBounds: cellFrame), in: controlView)
        }
    }
}
