// InlineRenameField.swift
// Limpid — inline rename: a label, and while it is renamed a TextField
// laid over it in its own frame.
//
// The field owns the whole rename, not just the swap: the draft, the
// double-click that starts it, and the rule for what a submit means, so
// no row keeps a copy of any of them. The label at rest is drawn from the
// model's name rather than the draft, so an empty submit cannot leave it
// blank; the draft only sizes the hidden label while an edit is open.
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
// The label stays in the layout while it is renamed, and the field is
// laid over it: the field takes the label's frame, so its width, its
// leading edge, and its font are the label's by construction and the
// row or the tab around it does not move as an edit begins or ends.
// Proposed the label's width, the plain field places its backing
// `NSTextField` 2pt out on either side and the field editor pads its
// text 2pt back in (`lineFragmentPadding`), which puts the first glyph
// exactly on the label's: measured on macOS 26 with a 2x bitmap of
// `Text` against the editing field at 11.5pt and 13pt, regular,
// medium, and semibold, first and last ink columns equal to the
// half point. So the field takes no leading correction at all.
// `InlineRenameGeometryTests` pins it, and fails if the OS moves it.
//
// That holds for a name that fits. The clip the field editor scrolls
// in starts a few points before the field, for its focus ring, and
// AppKit lines a name that fits up with the field by holding the clip
// at that slack's negative. A name longer than the field (a sidebar
// row's, cut to the row; a tab's title opens at its full width and
// rarely is) scrolls, and AppKit's scroll to its start, as the edit
// begins and whenever it comes back, stops at the clip's own edge, and
// TextKit 2, which the field editor lays out with, sets a scrolling
// text back by its line fragment padding besides, so the first glyph
// stood up to 5pt before the label's and the caret before it was cut
// in half. `InlineRenameEditorAlignment` moves that start to where a
// name that fits stands and insets the editor by whatever keeps its text
// container's origin at 0, so the glyphs stand on the label's however
// the field came to its start, with room before them for the whole
// caret. That inset is read from the origin rather than fixed, as the OS
// moves the origin differently: macOS 26 takes a name longer than the
// field to minus the padding and holds a name that fits at 0 under an
// inset of the padding, and macOS 27.2 holds both at 0 and adds the inset
// to the origin, so a fixed inset stood the glyphs 2pt after the label's.
//
// The label is also never narrower while it is renamed than it was at
// rest: until the field has seeded its draft it still draws the name,
// and from then on it is held at least as wide as the name the edit
// started from (`InlineRenameLabelText`). The field mounts a layout pass
// after the edit opens, so a label that drew the draft at once drew the
// last edit's leftover, or nothing on a first edit, and a tab narrowed
// to its caret and grew back, under the strip's rename animation too.
// Deleting text does not narrow it either until the edit ends, so a
// crowded strip's other tabs do not move with every keystroke.
//
// What the field draws is not bounded by its frame: the field editor's
// clip view starts 5pt before the label and ends 3.5pt after it, and
// a select-all paints from that leading edge. Left alone, a scrolled
// field's glyphs and its selection land on the badge or glyph beside
// the label. Cut at the label's own frame, as we first did, the
// selection and the first glyph's side bearing stand flush against a
// hard edge and a name longer than the frame is cut through a glyph,
// so the text reads as cut off even scrolled fully left. So, as
// Finder's inline rename does, the field stands in a quiet well that
// reaches a few points past the label on both sides
// (`InlineRenameEditingStyle.inline`): 2pt on the leading side, which
// is all the gap before a tab's badge has once its state mark (laid
// 3pt into the gap) is counted, and 3.5pt on the trailing side, where
// the field editor's own clip ends. The field is masked to the well,
// and on a side where text is scrolled out, what it draws past the
// label fades out across the outset, so a glyph scrolled past that
// edge dissolves instead of being cut. A side with nothing scrolled out
// stays solid, so the caret standing on it at the start or the end of
// the name is drawn whole, and nothing inside the label's frame is
// ever dimmed. The glyphs do not move: only the clip and the well grow,
// never the field or the label. The floating panel's field
// (`.boxed`) sits in a bordered box of its own, which draws the edge,
// so it keeps the hard clip at the label's frame plus the caret.
//
// Outside-click dismissal: SwiftUI's `@FocusState` only fires when a
// new view *takes* first responder. Clicking on the row's gutter or any
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
    /// Receives the submitted name, trimmed and never empty unless
    /// `submitsEmptyName` says otherwise, and only when it differs from the
    /// name the edit started from (`submission`). Nil for a label that cannot be
    /// renamed: it then never enters editing but is still drawn here, so a
    /// list that mixes the two keeps every label on the same left edge.
    var onRename: ((String) -> Void)?
    /// Whether the label claims the row's full width. Rows want it, so a
    /// double-click anywhere along them starts the rename; a label that
    /// shares its line with other text (the pane header's directory) sizes
    /// to its glyphs instead, or it would push that text off the line.
    var fillsWidth = true
    /// Where the label is cut when it does not fit. A name keeps its start;
    /// a tab's title that is a path keeps its end, where three shells in
    /// one project differ (`SupervisionTruncation.pathTitle`).
    var truncationMode: Text.TruncationMode = .tail
    /// While editing, the label takes the whole draft's width up to this
    /// limit rather than the width it is offered. A tab passes its title's
    /// limit, so a title the strip had cut to share its width opens for
    /// editing at its full length, which is what typing needs room for.
    /// Nil keeps the offered width, for a label whose line has other
    /// things on it that must keep their place (the pane header) or that
    /// already fills its row.
    var editingWidthLimit: CGFloat?
    /// Whether a blank submit reaches `onRename` as an empty string. Off
    /// for tabs and containers, whose name cannot be blank; on where the
    /// name is an override and clearing it hands the label back to a
    /// derived one, as a pane's name does.
    var submitsEmptyName = false
    /// Called by the double-click instead of starting the edit here, for a
    /// label whose owner decides where the edit happens. The pane header
    /// uses it to open a floating field when the name would be too narrow
    /// to edit in place. Nil starts the edit in this field, as the tab and
    /// container rows do.
    var onBeginRename: (() -> Void)?
    /// What VoiceOver calls the field while it is open: the label under it
    /// is hidden then, so without a name the field reads as a bare text
    /// field. A caller that knows what is renamed says so.
    var fieldName: LocalizedStringKey = "Name"
    /// How the open field meets what stands around the label: its own well
    /// and faded edges where it is laid over a label in a row, or a hard
    /// clip where its owner draws a box around it (the floating panel).
    var editingStyle: InlineRenameEditingStyle = .inline
    /// The text an edit starts from, when it is not the name drawn. A
    /// sidebar row that goes by its branch starts empty, so the branch is
    /// not taken for what the field renames: the field gives the row a
    /// label and leaves the branch as it is. Nil starts from `name`.
    var editsFrom: String?
    /// Drawn faint in the field while the draft is empty, so an edit that
    /// starts empty still shows what the label stands in for.
    var prompt: String?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var fieldFocused: Bool
    /// The text being typed. Seeded from `name` each time an edit
    /// starts and never drawn outside one.
    @State private var draft: String = ""
    /// The name the edit started from, which an untouched submit leaves
    /// alone (`submission`).
    @State private var startName: String = ""
    /// Whether this edit has set `draft` and `startName` from the name.
    /// Until it has, both hold the last edit's leftovers (or nothing), so
    /// the label is sized from the name instead (`InlineRenameLabelText`).
    @State private var isDraftSeeded = false
    @State private var didFinalize: Bool = false
    @State private var outsideClickMonitor: Any?
    /// The window the field is in, where its field editor is found.
    @State private var hostWindow = HostWindowReference()
    @State private var editorAlignment = InlineRenameEditorAlignment()

    /// What a submit renames to: the draft without surrounding
    /// whitespace, or nil when nothing is left. An empty or all-blank
    /// submit keeps the prior name rather than clearing it, unless the
    /// field sets `submitsEmptyName`, which hands the empty string on.
    nonisolated static func committedName(from draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What a submit hands to `onRename`: the new name; `""` for a blank
    /// submit where `submitsEmptyName` clears a name; nothing when the name
    /// is the one the edit started from, which renames nothing. The
    /// comparison is with the start and not with the name now, as the pane
    /// header's rule does (`PaneHeaderRules.nameChange`): a tab an agent
    /// retitles while it is being edited would otherwise have the old title
    /// pinned by an untouched submit, and a tab's name prefix would go with
    /// it.
    nonisolated static func submission(draft: String, startedFrom start: String, submitsEmptyName: Bool) -> String? {
        let name = committedName(from: draft)
        guard name != committedName(from: start) else { return nil }
        return name ?? (submitsEmptyName ? "" : nil)
    }

    /// Whether the field is drawn over the label: an edit is open on a
    /// label that can be renamed.
    private var isFieldShown: Bool {
        isEditing && onRename != nil
    }

    var body: some View {
        // While the field is shown the label draws the draft over the name
        // the edit started from, so the frame widens with a longer name (it
        // has room in a tab rather than scrolling inside the old name's
        // width) and holds its start width while text is deleted.
        sizedLabel
            .lineLimit(1)
            .truncationMode(truncationMode)
            // A draft typed down to nothing still leaves the caret a place.
            .frame(minWidth: isFieldShown ? InlineRenameEditingStyle.caretAllowance : nil, alignment: .leading)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            // SwiftUI's `Text` hit-tests only the drawn glyphs,
            // so a double-click to start a rename got a target
            // the width of the label itself — a one-character
            // tab name was basically un-double-clickable. Expand
            // hits to the full row-wide frame the parent already
            // laid out.
            .contentShape(Rectangle())
            .opacity(isFieldShown ? 0 : 1)
            .accessibilityHidden(isFieldShown)
            .overlay(alignment: .leading) {
                if isFieldShown {
                    field.mask { InlineRenameMask(style: editingStyle, overflow: editorAlignment.overflow) }
                }
            }
            // Under the label rather than in a frame of its own, so the
            // well takes no layout: the tab and the row keep their widths.
            .background {
                if isFieldShown, editingStyle.drawsWell {
                    InlineRenameWell(style: editingStyle, isContrastIncreased: contrast == .increased)
                }
            }
            .modifier(InlineRenameEditingWidth(limit: isFieldShown ? editingWidthLimit : nil))
            .font(font)
            .foregroundStyle(foregroundColor)
            // `simultaneousGesture` (not `.onTapGesture`) so this double-tap
            // recognizer doesn't gate single-click delivery to the inner
            // TextField while editing, as with the row's activation tap. Masked off entirely on a label that cannot be
            // renamed, so it never sits in that row's gesture arbitration.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard !isEditing else { return }
                    if let onBeginRename {
                        onBeginRename()
                    } else {
                        isEditing = true
                    }
                },
                including: onRename == nil ? .subviews : .all
            )
            // An edit its owner closed (a floating field whose request was
            // dropped or replaced) is abandoned, not committed: the owner's
            // promise is that it goes without committing. Without this the
            // field, still mounted while its panel fades out, would commit what
            // was typed when it later lost the keyboard.
            .onChange(of: isEditing) { _, editing in
                // The next edit sizes its label from the name until its
                // field seeds the draft again.
                if !editing {
                    isDraftSeeded = false
                }
                if Self.abandonsWhenClosedByOwner(isEditing: editing, didFinalize: didFinalize) {
                    didFinalize = true
                    removeEditingHooks()
                    fieldFocused = false
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                // An offscreen sidebar remains mounted for its slide animation.
                // Finalize explicitly so its shared field editor and event
                // monitor cannot keep receiving input after the sidebar closes.
                if !enabled, isEditing {
                    finalize(commit: true)
                }
            }
    }

    /// The label's text, over a hidden copy of the name the edit started
    /// from that holds its frame at least that wide, so the label never
    /// narrows as an edit opens or as text is deleted. At rest both are the
    /// name, which keeps the structure the same whether or not an edit is
    /// open.
    private var sizedLabel: some View {
        let label = InlineRenameLabelText(
            name: name,
            draft: draft,
            startName: startName,
            isFieldShown: isFieldShown,
            isDraftSeeded: isDraftSeeded
        )
        return ZStack(alignment: .leading) {
            Text(label.floor)
                .hidden()
                .accessibilityHidden(true)
            Text(label.text)
        }
    }

    private var field: some View {
        TextField("", text: $draft, prompt: prompt.map { Text(verbatim: $0) })
            .textFieldStyle(.plain)
            .accessibilityLabel(Text(fieldName))
            .focused($fieldFocused)
            .onSubmit { finalize(commit: true) }
            .onExitCommand { finalize(commit: false) }
            .onAppear {
                // Runs before the field's first frame, so it
                // never shows a previous edit's leftover text.
                draft = editsFrom ?? name
                startName = editsFrom ?? name
                isDraftSeeded = true
                didFinalize = false
                // Asked at mount, the focus is lost (a known
                // macOS 14+ quirk); asked once the terminal has
                // let go, the field keeps it.
                KeyboardHandoff.afterResponderSettles {
                    // The edit may have ended while we waited.
                    guard isEditing, !didFinalize else { return }
                    fieldFocused = true
                    installOutsideClickMonitor()
                }
            }
            .onDisappear {
                removeEditingHooks()
                // A field mounted again (the label turning renamable while
                // an edit is open) sizes from the name until it seeds again.
                isDraftSeeded = false
            }
            .onChange(of: fieldFocused) { _, focused in
                if Self.commitsOnFocusLoss(isFocused: focused, didFinalize: didFinalize) {
                    finalize(commit: true)
                }
                if focused {
                    attachEditorAlignment()
                }
            }
            .background(HostWindowReader(reference: hostWindow))
    }

    /// Aligns the field editor once it is in place: the keyboard is taken
    /// now, and the editor installed within a turn or a few, so we look
    /// again for a few turns rather than once.
    private func attachEditorAlignment(triesLeft: Int = 5) {
        guard isEditing, !didFinalize else { return }
        if editorAlignment.attach(in: hostWindow.window) || triesLeft == 0 {
            return
        }
        DispatchQueue.main.async {
            attachEditorAlignment(triesLeft: triesLeft - 1)
        }
    }

    /// Whether losing the keyboard commits the edit: only while it is
    /// still open. Once it has ended, by a submit, a cancel, or its owner
    /// closing it, losing the keyboard is just the field going away.
    nonisolated static func commitsOnFocusLoss(isFocused: Bool, didFinalize: Bool) -> Bool {
        !isFocused && !didFinalize
    }

    /// Whether `isEditing` turning false, from outside, abandons the edit.
    /// An edit this field ended itself has already finalized; any other
    /// way it closes is its owner dropping it.
    nonisolated static func abandonsWhenClosedByOwner(isEditing: Bool, didFinalize: Bool) -> Bool {
        !isEditing && !didFinalize
    }

    private func finalize(commit: Bool) {
        guard !didFinalize else { return }
        didFinalize = true
        removeEditingHooks()
        if commit, let name = Self.submission(draft: draft, startedFrom: startName, submitsEmptyName: submitsEmptyName) {
            onRename?(name)
        }
        // The keyboard goes as the edit ends, before the owner learns it
        // ended. A field kept on screen a moment longer, as a floating panel
        // fading out keeps it, must not still hold the keyboard when the
        // owner hands it back to the terminal.
        fieldFocused = false
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

    /// Lets go of what an open edit hooks into AppKit: the outside-click
    /// monitor and the field editor's alignment.
    private func removeEditingHooks() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        editorAlignment.detach()
    }
}

/// What the label draws, and the text it is held at least as wide as.
///
/// At rest both are the name. While the field is shown the label draws the
/// draft, held at least as wide as the name the edit started from, so the
/// field widens for a longer name and never narrows below the label it
/// was laid over. Until the field has seeded the draft, both are still the
/// name: the draft then holds the last edit's text, or nothing.
struct InlineRenameLabelText: Equatable {
    /// What the label draws, and so what a frame that follows it fits.
    let text: String
    /// Drawn hidden under `text`: the least the label is as wide as.
    let floor: String

    init(name: String, draft: String, startName: String, isFieldShown: Bool, isDraftSeeded: Bool) {
        if isFieldShown, isDraftSeeded {
            text = draft
            floor = startName
        } else {
            text = name
            floor = name
        }
    }
}

/// Keeps the start of a scrolling field where a field that fits stands,
/// so its first glyph stands on its label's (see the file's header).
///
/// The field editor scrolls in a clip that starts `slack` points before
/// the text field, its leading content inset. AppKit holds the clip of a
/// name that fits at `-slack`, which lines the text up with the field; its
/// scroll to the start of a name longer than the field stops at 0 instead,
/// the slack before it. We watch the clip and take a stop between
/// `-slack` and 0 to `-slack`: the same text from the same first glyph,
/// laid where the label's is. Anywhere further along the name is left to
/// AppKit.
///
/// It also says on which side text is scrolled out of the field, which
/// is where the mask fades (`InlineRenameMask`): an edge with nothing
/// scrolled past it is drawn solid, so the caret at the start or the end
/// of the name, which stands on that edge, is never dimmed.
@MainActor
@Observable
final class InlineRenameEditorAlignment {
    /// Whether text is scrolled out before the label's leading edge, or
    /// past its trailing one. Both until the field editor is read, so a
    /// field opened scrolled is never cut hard on its first frame.
    private(set) var overflow = InlineRenameOverflow.both

    /// Held weakly: the clip belongs to the text field, which goes with the
    /// edit, and is not ours to keep.
    @ObservationIgnored private weak var clip: NSClipView?
    @ObservationIgnored private var slack: CGFloat = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// The window's shared field editor, held weakly as it is the window's,
    /// and the inset it had before this edit, put back as the edit ends.
    @ObservationIgnored private weak var editor: NSTextView?
    @ObservationIgnored private var editorOriginalInset: NSSize?

    /// Starts watching the field editor at work in `window`. False while
    /// there is none yet.
    @discardableResult
    func attach(in window: NSWindow?) -> Bool {
        detach()
        guard let editor = window?.firstResponder as? NSTextView,
              editor.delegate is NSTextField,
              let clip = editor.superview as? NSClipView
        else { return false }
        // AppKit gives the clip its slack as a content inset (3pt at 13pt on
        // macOS 26), the room its own start of `-slack` stands in.
        let slack = clip.contentInsets.left
        self.clip = clip
        self.slack = slack
        // The editor is the window's shared one, so the inset it had goes back
        // as the edit ends.
        self.editor = editor
        editorOriginalInset = editor.textContainerInset
        clip.postsBoundsChangedNotifications = true
        editor.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        // Posted on the main thread, as views only change there. Scrolling
        // moves the clip's bounds; typing widens the editor.
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readOverflow()
                    // Aligned on the next turn: a move made while AppKit is
                    // still in its scroll is undone by the rest of that scroll.
                    DispatchQueue.main.async {
                        self?.align()
                        self?.alignTextContainer()
                    }
                }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: editor, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readOverflow()
                    // On the next turn: a change of inset lays the editor out
                    // again, which is not ours to start while its frame changes.
                    DispatchQueue.main.async { self?.alignTextContainer() }
                }
            }
        ]
        alignTextContainer()
        align()
        readOverflow()
        return true
    }

    func detach() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        clip = nil
        if let editor, let editorOriginalInset {
            editor.textContainerInset = editorOriginalInset
        }
        editor = nil
        editorOriginalInset = nil
        overflow = .both
    }

    /// The field editor's inset that takes its text container's origin to 0,
    /// never below the inset the editor had before the edit.
    nonisolated static func inset(_ inset: NSSize, containerOriginX: CGFloat, original: NSSize) -> NSSize {
        NSSize(width: max(inset.width - containerOriginX, original.width), height: inset.height)
    }

    /// Keeps the text container's origin at 0, where the glyphs stand on the
    /// label's (see the file's header for why it is read).
    private func alignTextContainer() {
        guard let editor, let editorOriginalInset else { return }
        let inset = Self.inset(
            editor.textContainerInset,
            containerOriginX: editor.textContainerOrigin.x,
            original: editorOriginalInset
        )
        if inset != editor.textContainerInset {
            editor.textContainerInset = inset
        }
    }

    private func align() {
        guard let clip,
              let x = Self.alignedOriginX(clip.bounds.origin.x, slack: slack)
        else { return }
        // Our own move posts the notification again and finds the clip
        // aligned. It cannot spin: a clip that held its origin somewhere else
        // would hold it at the same place on the next try too, and an origin
        // that does not change posts nothing.
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
    }

    private func readOverflow() {
        guard let clip, let editor = clip.documentView else { return }
        let read = Self.overflow(
            originX: clip.bounds.origin.x,
            visibleWidth: clip.bounds.width - clip.contentInsets.right,
            documentWidth: editor.frame.maxX,
            slack: slack
        )
        if read != overflow {
            overflow = read
        }
    }

    /// Which sides text is scrolled out on. The clip's origin past
    /// `-slack`, where a name that fits stands, has text before the
    /// label's leading edge; the editor, as wide as the text, reaching past
    /// the clip's visible end (its bounds short of its trailing inset) has
    /// text past the trailing one. A quarter point either way is rounding.
    nonisolated static func overflow(
        originX: CGFloat,
        visibleWidth: CGFloat,
        documentWidth: CGFloat,
        slack: CGFloat
    ) -> InlineRenameOverflow {
        InlineRenameOverflow(
            hasLeadingOverflow: originX > -slack + 0.25,
            hasTrailingOverflow: documentWidth > originX + visibleWidth + 0.25
        )
    }

    /// Where the clip should stand instead of `x`, or nil to leave it: a
    /// stop at the start, between `-slack` and 0, goes to `-slack`.
    nonisolated static func alignedOriginX(_ x: CGFloat, slack: CGFloat) -> CGFloat? {
        x <= 0 && x > -slack ? -slack : nil
    }
}

/// The sides of an open field with text scrolled out past them.
struct InlineRenameOverflow: Equatable {
    var hasLeadingOverflow: Bool
    var hasTrailingOverflow: Bool

    static let both = InlineRenameOverflow(hasLeadingOverflow: true, hasTrailingOverflow: true)
}

/// How far an open field may draw past its label's frame, and how it
/// ends there.
enum InlineRenameEditingStyle: Equatable {
    /// Laid over a label in a row: a well a few points past the label on
    /// both sides, and what the field draws there fades out.
    case inline
    /// In a box its owner draws: clipped hard to the label's frame, with
    /// room past the trailing edge for the caret alone.
    case boxed

    /// The least a field emptied of its text keeps for its caret, and the
    /// room a boxed field keeps for it past the trailing edge.
    static let caretAllowance: CGFloat = 2
    /// How far the caret reaches past the spot it stands on: half its
    /// drawn width of about 2pt. At the end of the name the caret stands on
    /// the label's trailing edge and reaches this far past it, so the fade
    /// starts after it and never dims it.
    static let caretWidth: CGFloat = 1

    /// How far before the label the field may draw. An inline field gets
    /// 2pt: the gap before a tab's title is 6pt, and the state mark laid on
    /// the badge's corner reaches 3pt into it, so 2pt still leaves the mark
    /// a point clear. The sidebar row's gap (8pt) and the pane header's
    /// (4pt, before a glyph centered in its slot) have more room.
    var leadingOutset: CGFloat {
        switch self {
        case .inline: 2
        case .boxed: 0
        }
    }

    /// How far past the label the field may draw. An inline field gets
    /// 3.5pt, where the field editor's own clip ends (measured on macOS 26
    /// at 11.5pt and 13pt): a fade that ended short of it would leave a cut
    /// glyph at the field editor's edge, and past it there is nothing left
    /// to fade.
    var trailingOutset: CGFloat {
        switch self {
        case .inline: 3.5
        case .boxed: Self.caretAllowance
        }
    }

    /// Whether what the field draws past the label fades out rather than
    /// being cut. Contrast settings leave it on: it touches only glyphs
    /// already scrolled out of the field, never what can be read in it.
    var fadesEdges: Bool {
        self == .inline
    }

    /// Whether the field draws its own well. A boxed field's owner draws
    /// the box.
    var drawsWell: Bool {
        self == .inline
    }
}

/// The open field's mask: solid over the label's frame, and over each
/// outset solid, or fading to nothing where an inline field has text
/// scrolled out past that edge. Laid out in the field's frame, which is
/// the label's, and reaching past it by the outsets.
///
/// An edge fades only while text is scrolled past it. The caret at the
/// start of the name stands on the leading edge and the system's caret
/// is drawn reaching into the outset, so a fade kept there at the start
/// dimmed it to almost nothing; with nothing scrolled out there is no
/// glyph to fade, and the outset is solid. The trailing fade keeps the
/// caret's width solid as well, for a caret further along.
struct InlineRenameMask: View {
    let style: InlineRenameEditingStyle
    let overflow: InlineRenameOverflow

    var body: some View {
        HStack(spacing: 0) {
            edge(fadingTowards: .leading, fades: overflow.hasLeadingOverflow)
                .frame(width: style.leadingOutset)
            Color.black
            HStack(spacing: 0) {
                if style.fadesEdges, overflow.hasTrailingOverflow {
                    Color.black.frame(width: InlineRenameEditingStyle.caretWidth)
                }
                edge(fadingTowards: .trailing, fades: overflow.hasTrailingOverflow)
            }
            .frame(width: style.trailingOutset)
        }
        .padding(.leading, -style.leadingOutset)
        .padding(.trailing, -style.trailingOutset)
    }

    @ViewBuilder
    private func edge(fadingTowards side: HorizontalEdge, fades: Bool) -> some View {
        if style.fadesEdges, fades {
            LinearGradient(
                colors: side == .leading ? [.clear, .black] : [.black, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color.black
        }
    }
}

/// The well an inline field stands in: the label's frame and the outsets
/// on either side, a point taller than the line above and below so the
/// selection sits inside it. With Increase Contrast it takes an edge, so
/// where the field ends is drawn and not only tinted.
private struct InlineRenameWell: View {
    let style: InlineRenameEditingStyle
    let isContrastIncreased: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.inlineRenameWellCornerRadius, style: .continuous)
        shape
            .fill(SupervisionTokens.renameWell.color)
            .overlay {
                if isContrastIncreased {
                    shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
            .padding(.leading, -style.leadingOutset)
            .padding(.trailing, -style.trailingOutset)
            .padding(.vertical, -LimpidLayout.inlineRenameWellVerticalOutset)
            .accessibilityHidden(true)
    }
}

/// Holds the editing label at its own width up to `limit`, whatever it is
/// offered, so the row around it gives the field room instead of cutting
/// it. A nil limit passes the offer through unchanged.
private struct InlineRenameEditingWidth: ViewModifier {
    let limit: CGFloat?

    func body(content: Content) -> some View {
        InlineRenameEditingWidthLayout(limit: limit) { content }
    }
}

private struct InlineRenameEditingWidthLayout: Layout {
    let limit: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(offer(for: proposal, to: subview))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(at: bounds.origin, proposal: offer(for: proposal, to: subview))
    }

    private func offer(for proposal: ProposedViewSize, to subview: LayoutSubview) -> ProposedViewSize {
        guard let limit else { return proposal }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).width
        return ProposedViewSize(width: min(ideal, limit), height: proposal.height)
    }
}
