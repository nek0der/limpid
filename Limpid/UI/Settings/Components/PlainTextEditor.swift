// PlainTextEditor.swift
// Limpid — SwiftUI wrapper around `NSTextView` with every macOS
// smart-input substitution turned off. We reach for this anywhere a
// user-typed value is later handed to `sh -c` / `eval` (the Bootstrap
// commands editor is the first caller), because the system's default
// auto-conversion silently rewrites characters and breaks shell
// parsing — a literal `"` becomes `“` / `”`, `--` becomes `—`, and so
// on. Once the substitution lands, the on-disk command is no longer
// what the user typed, but they can't tell from the UI.

import AppKit
import SwiftUI

/// Monospaced, scrolling text editor that doesn't rewrite user input.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            configure(textView, with: context.coordinator)
            disableWordWrap(textView)
        }
        return scrollView
    }

    /// Shell commands are 1-line atoms — wrapping them onto two visual
    /// lines reads as "two separate commands" to the user. Turn off
    /// word wrap and let the horizontal scroller handle overflow.
    private func disableWordWrap(_ textView: NSTextView) {
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        if let container = textView.textContainer {
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            container.widthTracksTextView = false
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only push to the view when the binding actually diverged.
        // Without this we'd clobber the user's selection on every
        // keystroke — the delegate fires `text = textView.string`,
        // SwiftUI re-runs `updateNSView`, and a blind `textView.string
        // = text` resets the cursor to the end.
        if textView.string != text {
            textView.string = text
        }
    }

    private func configure(_ textView: NSTextView, with coordinator: Coordinator) {
        textView.delegate = coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize,
            weight: .regular
        )
        // The whole point of this wrapper: stop macOS from rewriting
        // user input behind our back. Every default-on substitution
        // in `NSTextView` is a foot-gun for shell-bound text.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
