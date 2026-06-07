// SurfaceView+TextInput.swift
// Limpid — NSTextInputClient (IME / marked-text) conformance. Split
// out of SurfaceView.swift to keep that file under the SwiftLint line
// cap; logically part of the surface view's keyboard pipeline.

import AppKit
import GhosttyKit

extension SurfaceView: @preconcurrency NSTextInputClient {
    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let str: String
        switch string {
        case let s as NSAttributedString: str = s.string
        case let s as String: str = s
        default: return
        }
        markedText = str
        pushPreedit()
    }

    func unmarkText() {
        if !markedText.isEmpty {
            markedText = ""
            pushPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Composition is done; clear preedit before committing the text.
        unmarkText()
        let chars: String
        switch string {
        case let s as NSAttributedString: chars = s.string
        case let s as String: chars = s
        default: return
        }
        guard !chars.isEmpty else { return }

        // If we're inside a keyDown dispatch, accumulate so the caller can
        // forward the committed text as a normal key event (lets libghostty's
        // encoder run on it). Otherwise the call came from outside the key
        // pipeline (voice input, accessibility) — send as paste.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        guard let surface else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Place the IME candidate window near the view origin. Proper caret
        // tracking lives in a later phase (query libghostty for the cursor
        // rectangle).
        guard let window else { return .zero }
        let viewRect = NSRect(origin: .zero, size: .zero)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    override func doCommand(by selector: Selector) {
        if hasMarkedText() {
            // Newline selectors during composition: commit the text
            // via the paste path (ghostty_surface_text) to bypass
            // keybind matching — forward() would hit the
            // shift+enter=text:\n bind and discard the text.
            guard selector == #selector(insertNewline(_:))
                || selector == #selector(insertLineBreak(_:))
            else { return }

            let text = markedText
            unmarkText()
            if let surface, !text.isEmpty {
                text.withCString { ptr in
                    ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
                }
            }
            // Clear the accumulator so keyDown doesn't re-send.
            keyTextAccumulator = []
            // Fall through to also forward the newline key event.
        }

        if let event = activeKeyEvent ?? NSApp.currentEvent, event.type == .keyDown {
            forward(event, action: GHOSTTY_ACTION_PRESS)
        }
    }

    /// Preedit (marked text) push, used only by the IME methods above.
    private func pushPreedit() {
        guard let surface else { return }
        markedText.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr)))
        }
    }
}
