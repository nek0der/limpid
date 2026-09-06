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

    /// The input system reads this to find the insertion point.
    /// `NSNotFound` reads as "this client holds no text at all", which
    /// leaves Dictation with nowhere to anchor, so we report the live
    /// selection — empty at the caret — the way a text view would.
    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let str: String
        switch string {
        case let s as NSAttributedString: str = s.string
        case let s as String: str = s
        default: return
        }
        if markedText.isEmpty, !str.isEmpty {
            compositionStartedAt = ProcessInfo.processInfo.systemUptime
            asynchronousCompositionInterval = nil
        }
        markedText = str
        pushPreedit()
    }

    func unmarkText() {
        compositionStartedAt = nil
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
        let compositionStart = compositionStartedAt
        let commitTime = ProcessInfo.processInfo.systemUptime
        // Composition is done; clear preedit before committing the text.
        unmarkText()
        let chars: String
        switch string {
        case let s as NSAttributedString: chars = s.string
        case let s as String: chars = s
        default: return
        }
        guard !chars.isEmpty else { return }

        if keyTextAccumulator == nil, let compositionStart {
            asynchronousCompositionInterval = compositionStart...commitTime
        }

        // If we're inside a keyDown dispatch, accumulate so the caller can
        // forward the committed text as a normal key event (lets libghostty's
        // encoder run on it). Otherwise the call came from outside the key
        // pipeline (voice input, accessibility) and we commit it here.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        // Dictation and accessibility clients both reach this path and
        // both can deliver a bare control character.
        guard !Self.isSuppressibleControlInput(chars) else { return }
        commitText(chars)
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let viewRect = Self.imeViewRect(
            from: NSRect(x: x, y: y, width: width, height: height),
            range: range,
            viewHeight: bounds.height
        )
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    override func doCommand(by selector: Selector) {
        if hasMarkedText() {
            // Newline selectors during composition: commit the text
            // without a physical key so keybind matching can't fire —
            // forward() would hit the shift+enter=text:\n bind and
            // discard the text.
            guard selector == #selector(insertNewline(_:))
                || selector == #selector(insertLineBreak(_:))
            else { return }

            let text = markedText
            unmarkText()
            if !text.isEmpty {
                commitText(text)
            }
            // Clear the accumulator so keyDown doesn't re-send.
            keyTextAccumulator = []
            // Fall through to also forward the newline key event.
        }

        if let event = activeKeyEvent ?? NSApp.currentEvent, event.type == .keyDown {
            forward(event, action: GHOSTTY_ACTION_PRESS)
        }
    }

    /// `imeRect` carries libghostty's caret in top-left origin
    /// coordinates, with `y` on the cell's bottom edge and the width
    /// spanning the preedit run. AppKit wants a bottom-left origin, and
    /// the dictation microphone indicator anchors on the rect's leading
    /// edge — a preedit-wide rect would push it past the caret — so an
    /// empty range collapses the width.
    static func imeViewRect(
        from imeRect: NSRect,
        range: NSRange,
        viewHeight: CGFloat
    ) -> NSRect {
        NSRect(
            x: imeRect.origin.x,
            y: viewHeight - imeRect.origin.y,
            width: range.length == 0 ? 0 : imeRect.width,
            height: imeRect.height
        )
    }

    /// Preedit (marked text) push, used only by the IME methods above.
    private func pushPreedit() {
        guard let surface else { return }
        markedText.withCString { ptr in
            ghostty_surface_preedit(surface, ptr, UInt(strlen(ptr)))
        }
    }
}
