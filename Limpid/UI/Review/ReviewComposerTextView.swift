// ReviewComposerTextView.swift
// Limpid — composition notifications for the comment field's placeholder.

import AppKit

final class ReviewComposerTextView: NSTextView {
    /// Set by the row after construction; marked text does not reliably emit textDidChange.
    var onCompositionChanged: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChanged?()
    }
}
