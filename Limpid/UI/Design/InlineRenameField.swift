// InlineRenameField.swift
// Limpid — Text ↔ TextField swap, the macOS 2026 industry-standard
// pattern for sidebar inline rename.
//
// Why the swap (and NOT "always-on TextField + .focusable toggle"):
//
//   - SwiftUI's TextField on macOS is backed by `NSTextField`, which
//     borrows `NSWindow`'s *shared* field editor (`NSTextView`) on
//     focus. Editing a long label leaves the field editor's
//     `NSClipView` bounds.origin scrolled. The reused `NSTextField`
//     backing + that residual offset bleeds into other rows the
//     next time SwiftUI repaints them, even in display mode.
//   - Going `Text` for display and only spawning `TextField` while
//     editing means the `NSTextField` backing is created fresh per
//     edit and torn down on commit — there's no residual state to
//     leak into other rows. This is the reliable shape on
//     macOS 12 → 26.
//
// Text vs TextField differ by ~5pt because the TextField field
// editor adds a default `lineFragmentPadding`. We compensate by
// padding the display `Text` so the static label sits at the same
// x as the editing field — no jump when the row enters / leaves
// edit mode.
//
// Outside-click dismissal: SwiftUI's `@FocusState` only fires when a
// new view *takes* first responder. Clicking on the slab gutter or any
// non-focusable region leaves the field editor as first responder and
// the rename UI feels stuck open. We install an `NSEvent` local monitor
// while editing and use AppKit `hitTest` to ask "did this click land
// inside our field's NSTextField subtree?" — anything else commits.
// `hitTest` works in native AppKit view coords, so we avoid the
// SwiftUI-`.global` vs `NSWindow.contentLayoutRect` flip math entirely
// (that flip was off by the title-bar height under `.fullSizeContentView`,
// which caused inside clicks to be misclassified as outside and the
// field to collapse on every keystroke-adjacent tap).

import AppKit
import SwiftUI

struct InlineRenameField: View {
    @Binding var text: String
    @Binding var isEditing: Bool
    var font: Font
    var foregroundColor: Color
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var rollback: String = ""
    @State private var didFinalize: Bool = false
    @State private var outsideClickMonitor: Any?

    /// Match the field editor's default `lineFragmentPadding` so the
    /// static `Text` lines up with the editing TextField's first
    /// glyph.
    private static let fieldEditorLeadingPadding: CGFloat = 5

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { finalize(commit: true) }
                    .onExitCommand { finalize(commit: false) }
                    .onAppear {
                        rollback = text
                        didFinalize = false
                        // Mount-time `.task` focus loss is a known
                        // macOS 14+ quirk; bumping focus to the next
                        // runloop tick sidesteps it.
                        DispatchQueue.main.async {
                            fieldFocused = true
                            installOutsideClickMonitor()
                        }
                    }
                    .onDisappear { removeOutsideClickMonitor() }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused, !didFinalize {
                            finalize(commit: true)
                        }
                    }
            } else {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, Self.fieldEditorLeadingPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // SwiftUI's `Text` hit-tests only the drawn glyphs,
                    // so callers that attach `.onTapGesture(count: 2)`
                    // to start a rename get a target the width of the
                    // label itself — a one-character tab name was
                    // basically un-double-clickable. Expand hits to the
                    // full row-wide frame the parent already laid out.
                    .contentShape(Rectangle())
            }
        }
        .font(font)
        .foregroundStyle(foregroundColor)
    }

    private func finalize(commit: Bool) {
        guard !didFinalize else { return }
        didFinalize = true
        removeOutsideClickMonitor()
        if commit {
            onCommit(text)
        } else {
            text = rollback
            onCancel()
        }
        isEditing = false
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            // Ask AppKit directly: does this click land on the
            // NSTextField we're editing (or its field editor)? We get
            // the field via the window's current first responder — when
            // we own focus, that's the shared field editor and its
            // `delegate` is our backing `NSTextField`. `hitTest` returns
            // the deepest descendant view at the click point, so an
            // ancestry check tells us "click landed somewhere within
            // our text field's visual subtree" reliably regardless of
            // window toolbar (`.fullSizeContentView`, toolbar height,
            // etc.).
            guard let win = event.window,
                  let contentView = win.contentView,
                  let hit = contentView.hitTest(event.locationInWindow)
            else {
                return event
            }
            if let editor = win.firstResponder as? NSText {
                if hit === editor || hit.isDescendant(of: editor) {
                    return event
                }
                if let textField = editor.delegate as? NSTextField,
                   hit === textField || hit.isDescendant(of: textField)
                {
                    return event
                }
            }
            DispatchQueue.main.async {
                guard isEditing, !didFinalize else { return }
                finalize(commit: true)
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}
