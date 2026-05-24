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
//     leak into other rows. Confirmed by Apple Forums #744173,
//     CocoaDev "CustomFieldEditor", and the wider community as the
//     reliable shape on macOS 12 → 26.
//
// Text vs TextField differ by ~5pt because the TextField field
// editor adds a default `lineFragmentPadding`. We compensate by
// padding the display `Text` so the static label sits at the same
// x as the editing field — no jump when the row enters / leaves
// edit mode.

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
    /// NSEvent monitor that finalizes the edit when the user clicks
    /// anywhere outside this `TextField`'s frame. SwiftUI's
    /// `@FocusState` only fires when a new view *takes* first
    /// responder — clicking on the slab gutter or any non-focusable
    /// region leaves the field editor as first responder and the
    /// rename UI feels stuck open. The monitor compares the click
    /// position against the field's window-coordinate frame
    /// (captured via `GeometryReader`) and commits whenever the
    /// click misses.
    @State private var outsideClickMonitor: Any?
    @State private var fieldFrameInWindow: CGRect = .zero

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
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    fieldFrameInWindow = geo.frame(in: .global)
                                }
                                .onChange(of: geo.frame(in: .global)) { _, new in
                                    fieldFrameInWindow = new
                                }
                        }
                    )
                    .onSubmit { finalize(commit: true) }
                    .onExitCommand { finalize(commit: false) }
                    .onAppear {
                        rollback = text
                        didFinalize = false
                        // Mount-time `.task` focus loss is a known
                        // macOS 14+ quirk (Apple Forums #744173);
                        // bumping focus to the next runloop tick
                        // sidesteps it.
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
            // Compare the click location against the field's frame in
            // SwiftUI window coordinates. SwiftUI's `.global` space and
            // `event.locationInWindow` both use AppKit window-local
            // coords but with opposite y axes — flip the y before the
            // hit test. Inside-frame clicks (positioning the caret) are
            // ignored; everything else commits, including clicks on
            // empty slab area that AppKit otherwise ignores (those
            // never reach `@FocusState`, which is why the field used
            // to feel stuck in edit mode).
            if let win = event.window {
                let flipped = CGPoint(
                    x: event.locationInWindow.x,
                    y: win.contentLayoutRect.height - event.locationInWindow.y
                )
                if !fieldFrameInWindow.contains(flipped) {
                    DispatchQueue.main.async {
                        guard isEditing, !didFinalize else { return }
                        finalize(commit: true)
                    }
                }
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
