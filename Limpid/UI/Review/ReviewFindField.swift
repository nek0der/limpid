// ReviewFindField.swift
// Limpid — the find bar's text field.

import AppKit
import SwiftUI

/// AppKit rather than SwiftUI's `TextField`.
///
/// A field editor answers Escape and Return itself and reports neither
/// onward, so `.onKeyPress`, `.onExitCommand` and a `.cancelAction` button
/// beside the field all stay silent: the bar could be opened from the keyboard
/// and then only dismissed with the mouse. The delegate below is where those
/// keys actually arrive.
struct ReviewFindField: NSViewRepresentable {
    @Binding var text: String
    /// Return moves forward, Shift-Return back.
    let onMove: (Int) -> Void
    let onCancel: () -> Void
    /// Bumped every time the reader asks for the find bar. The bar is already
    /// mounted the second time they ask, so nothing would otherwise bring the
    /// keyboard back to it — and the Find key reads as broken when the field
    /// it names is on screen and does not answer.
    let focusRequest: Int

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11)
        field.placeholderString = String(localized: "Find in file")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only when they disagree: assigning while the reader is typing moves
        // the insertion point to the end of what they have written.
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        // One path for the focus, including the first one: `updateNSView` runs
        // right after the view is made, and taking first responder from
        // `makeNSView` as well would fight whatever this hands it to next.
        guard context.coordinator.appliedFocusRequest != focusRequest else { return }
        context.coordinator.appliedFocusRequest = focusRequest
        // After the window has had the frame the bar was mounted in.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ReviewFindField
        /// The last request this field answered. Without it every update would
        /// take first responder back from whatever else has it.
        var appliedFocusRequest: Int?

        init(_ parent: ReviewFindField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // Shift-Return arrives as the same command, so the modifier is
                // read off the event that produced it.
                let isBackward = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                parent.onMove(isBackward ? -1 : 1)
                return true
            default:
                return false
            }
        }
    }
}
