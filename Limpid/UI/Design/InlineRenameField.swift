// InlineRenameField.swift
// Limpid — Text ↔ TextField swap, the macOS 2026 industry-standard
// pattern for sidebar inline rename.
//
// The field owns the whole rename, not just the swap: the draft, the
// double-click that starts it, and the rule for what a submit means.
// `TabRow` and `ContainerRow` each used to keep their own draft and
// their own copy of that rule, and had to resync the draft by hand
// after an empty submit or the label went blank. Drawing the label
// from the model's name instead of the draft removes that step.
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
    /// The name as the model holds it. Drawn whenever the field is not
    /// editing, and what an edit starts from.
    let name: String
    /// Owned by the row, which opens an edit from its context menu or a
    /// shortcut by setting this and reads it to hold off its own taps.
    @Binding var isEditing: Bool
    var font: Font
    var foregroundColor: Color
    /// Receives the submitted name, trimmed and never empty. Nil for a
    /// label that cannot be renamed: it then never enters editing but is
    /// still drawn here, so a list that mixes the two keeps every label
    /// on the same left edge.
    var onRename: ((String) -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var fieldFocused: Bool
    /// The text being typed. Seeded from `name` each time an edit
    /// starts and never drawn outside one.
    @State private var draft: String = ""
    @State private var didFinalize: Bool = false
    @State private var outsideClickMonitor: Any?

    /// Match the field editor's default `lineFragmentPadding` so the
    /// static `Text` lines up with the editing TextField's first
    /// glyph.
    private static let fieldEditorLeadingPadding: CGFloat = 5

    /// What a submit renames to: the draft without surrounding
    /// whitespace, or nil when nothing is left. An empty or all-blank
    /// submit keeps the prior name rather than clearing it.
    nonisolated static func committedName(from draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        Group {
            if isEditing, onRename != nil {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { finalize(commit: true) }
                    .onExitCommand { finalize(commit: false) }
                    .onAppear {
                        // Runs before the field's first frame, so it
                        // never shows a previous edit's leftover text.
                        draft = name
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
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, Self.fieldEditorLeadingPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // SwiftUI's `Text` hit-tests only the drawn glyphs,
                    // so a double-click to start a rename got a target
                    // the width of the label itself — a one-character
                    // tab name was basically un-double-clickable. Expand
                    // hits to the full row-wide frame the parent already
                    // laid out.
                    .contentShape(Rectangle())
            }
        }
        .font(font)
        .foregroundStyle(foregroundColor)
        // `simultaneousGesture` (not `.onTapGesture`) so this double-tap
        // recognizer doesn't gate single-click delivery to the inner
        // TextField while editing — same lesson as PR #50 for the row's
        // activation tap. Masked off entirely on a label that cannot be
        // renamed, so it never sits in that row's gesture arbitration.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if !isEditing {
                    isEditing = true
                }
            },
            including: onRename == nil ? .subviews : .all
        )
        .onChange(of: isEnabled) { _, enabled in
            // An offscreen sidebar remains mounted for its slide animation.
            // Finalize explicitly so its shared field editor and event
            // monitor cannot keep receiving input after the sidebar closes.
            if !enabled, isEditing {
                finalize(commit: true)
            }
        }
    }

    private func finalize(commit: Bool) {
        guard !didFinalize else { return }
        didFinalize = true
        removeOutsideClickMonitor()
        if commit, let newName = Self.committedName(from: draft) {
            onRename?(newName)
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
