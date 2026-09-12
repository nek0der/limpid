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

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = searchLabel
        field.setAccessibilityLabel(searchLabel)
        field.controlSize = .small
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
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
