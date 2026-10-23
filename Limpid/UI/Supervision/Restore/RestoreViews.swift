// RestoreViews.swift
// Limpid — the restore strip in a decision bar, and the record of a restore in the bar and the changes panel.

import SwiftUI

/// The restore strip, in a pane's decision bar while it is open:
/// which turns' changes go and what stays, "Restore Code" and "Cancel";
/// then that it is running, or how it ended short of the whole restore.
/// Neutral, not the stop's red: it is a question, not news.
///
/// Opened, it takes the keyboard from the terminal: Return restores
/// and Escape cancels, and only while the strip has it, so neither reaches
/// the agent by mistake. The strip, not its button, takes it: a button
/// takes the keyboard only with Full Keyboard Access on. Once the strip
/// has done its part the keyboard goes back to the terminal, whether a key
/// or the mouse ended it.
struct RestoreStripView: View {
    let paneID: UUID
    let strip: RestoreStrip
    let handler: RestoreHandler
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.surfaceRegistry) private var registry
    @Environment(\.locale) private var locale
    @State private var isKeyboardActive = false
    @FocusState private var isFocused: Bool

    var body: some View {
        // In the decision bar's foot bar, on the sidebar's ground under the
        // `line` rule, as the bar at rest.
        SupervisionFootBar(fill: SupervisionTokens.sidebar.color) {
            row
        }
        // An opaque ground, as the decision bar's: its buttons fill opaquely.
        .environment(\.supervisionSurfaceOpacity, 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Code Restore", comment: "Restore strip, VoiceOver: the region holding the question"))
        .focusable(isKeyboardActive)
        .focusEffectDisabled()
        .focused($isFocused)
        .onChange(of: window.restoreFocusRequest, initial: true) { _, request in
            guard request == paneID else { return }
            window.restoreFocusRequest = nil
            isKeyboardActive = true
            // Once the strip is focusable and the terminal has let go.
            KeyboardHandoff.afterResponderSettles { isFocused = true }
        }
        .onChange(of: isFocused) { _, isFocused in
            if !isFocused {
                isKeyboardActive = false
            }
        }
        .onKeyPress(.return, phases: .down) { press in
            // Return alone, or the keypad's Enter: ⇧⏎ or ⌥⏎ is meant for
            // something else.
            guard isFocused, strip.phase == .confirming, press.modifiers.subtracting(.numericPad).isEmpty else {
                return .ignored
            }
            restore()
            return .handled
        }
        .onKeyPress(.escape) {
            guard isFocused else { return .ignored }
            close()
            return .handled
        }
        // Put aside while the pane's agent asks something
        // (`RestoreStrip.yields`): the terminal answers it.
        .onDisappear {
            if isFocused || isKeyboardActive {
                KeyboardHandoff.returnToTerminal(paneID: paneID, registry: registry, keeper: .terminalOrTextField, timing: .nextTurn)
            }
        }
    }

    private var row: some View {
        RestoreStripRow(
            strip: strip,
            confirmation: handler.confirmation(strip, locale),
            isFocused: isFocused,
            onRestore: restore,
            onClose: close
        )
    }

    /// "Restore Code", by Return or the mouse. The strip goes or says how
    /// it ended; the terminal is where the person works next either way.
    private func restore() {
        handler.confirm(paneID, locale)
        giveBackKeyboard()
    }

    private func close() {
        handler.cancel(paneID)
        giveBackKeyboard()
    }

    private func giveBackKeyboard() {
        isFocused = false
        isKeyboardActive = false
        KeyboardHandoff.returnToTerminal(paneID: paneID, registry: registry, keeper: .terminalOrTextField, timing: .nextTurn)
    }
}

/// The restore strip's row: its tag, its words, and its buttons, from the
/// strip and its question alone, so it can be measured against a pane as
/// the decision bar's row is. In a pane too narrow for the whole row it
/// takes a narrower fit (`Fit`) rather than push its buttons past the
/// pane's edge, where they were cut from sight in one of two panes side
/// by side in a 730pt window.
///
/// Its buttons stay out of the ⇥ order: ⇥ is the terminal's, for its
/// TUI. The strip itself takes the keyboard when it opens, where Return
/// restores and Escape cancels, and VoiceOver presses the buttons.
struct RestoreStripRow: View {
    /// How much of the strip stands in its row, widest first; the row
    /// takes the first that fits, as the decision bar's does
    /// (`DecisionBarModel.Fit`).
    enum Fit: CaseIterable {
        /// The tag, the words with room for a few of them, and the buttons
        /// in words.
        case full
        /// Without the tag, which the strip's ground and its question
        /// still carry and VoiceOver reads ahead of the words; "Restore
        /// Code" as "Restore", whole in its VoiceOver label. Chosen while
        /// the buttons fit at all, the words cut as short as they must be.
        case minimal
        /// The words alone, for a pane too narrow for any button: a button
        /// laid out past the pane's edge would be cut from sight but still
        /// take clicks there. Return and Escape still answer the strip.
        case wordsOnly
    }

    let strip: RestoreStrip
    /// What the strip asks; `nil` when its turn is gone.
    let confirmation: RestoreConfirmation?
    /// Whether the strip has the keyboard, so Return presses "Restore Code".
    let isFocused: Bool
    /// The fits the row may take, widest first; all of them but for a test
    /// that measures one on its own.
    var fits: [Fit] = Fit.allCases
    let onRestore: () -> Void
    let onClose: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(fits, id: \.self) { fit in
                row(fit)
            }
        }
    }

    private func row(_ fit: Fit) -> some View {
        HStack(spacing: LimpidLayout.Supervision.spaceS) {
            if fit == .full {
                DecisionBarTag(text: RestoreText.stripTag(locale: locale), tone: .muted)
            }
            // Measured with the words at no more than their least where the
            // fit keeps them, or at nothing where it is chosen while its
            // buttons fit at all; the fit chosen then gives them the rest.
            IdealWidthCap(maxIdealWidth: fit == .full ? LimpidLayout.Supervision.decisionBarTextMinWidth : 0) {
                words(includesSpokenTag: fit != .full)
            }
            if fit != .wordsOnly {
                Spacer(minLength: LimpidLayout.Supervision.spaceS)
                trailing(isShort: fit == .minimal)
            }
        }
    }

    /// The question and what stays, or how the restore ended. Where the
    /// row has no room for the tag, VoiceOver reads it ahead of the words.
    @ViewBuilder
    private func words(includesSpokenTag: Bool) -> some View {
        let tag = includesSpokenTag ? RestoreText.stripTag(locale: locale) : nil
        switch strip.phase {
        case .confirming, .running:
            // While the gate holds it back, why, in place of what stays:
            // the disabled button alone would not say.
            let note = confirmation?.blockedReason ?? confirmation?.note ?? ""
            HStack(spacing: LimpidLayout.Supervision.spaceS) {
                // The question in semibold, its "+94" and "−2" in the diff
                // colors.
                ReceiptRunsText(runs: confirmation?.textRuns(locale: locale) ?? [], size: .row, base: SupervisionTokens.text.color)
                    .lineLimit(1)
                    .supervisionTruncation(.sentence)
                    .help(Text(verbatim: confirmation?.help(locale: locale) ?? ""))
                    .accessibilityLabel(Text(verbatim: Self.spoken(confirmation?.text ?? "", tag: tag, locale: locale)))
                Text(verbatim: note)
                    .font(.supervision(.row))
                    .foregroundStyle(confirmation?.blockedReason == nil ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                    .lineLimit(1)
                    .supervisionTruncation(.sentence)
                    .layoutPriority(-1)
                    .help(Text(verbatim: note))
            }
        case let .ended(message):
            Text(verbatim: message)
                .font(.supervision(.row, weight: .medium))
                .foregroundStyle(SupervisionTokens.text.color)
                .lineLimit(1)
                .supervisionTruncation(.sentence)
                .help(Text(verbatim: message))
                .accessibilityLabel(Text(verbatim: Self.spoken(message, tag: tag, locale: locale)))
        }
    }

    /// `text`, after the tag where the row does not show it.
    private static func spoken(_ text: String, tag: String?, locale: Locale) -> String {
        guard let tag else { return text }
        return AgentStatusText.spokenList([tag, text], locale: locale)
    }

    /// "Restore Code" and "Cancel", that it is running, or "Close".
    @ViewBuilder
    private func trailing(isShort: Bool) -> some View {
        switch strip.phase {
        case .running:
            ProgressView()
                .controlSize(.small)
            Text(verbatim: RestoreText.restoring(locale: locale))
                .font(.supervision(.row))
                .foregroundStyle(SupervisionTokens.muted.color)
                .fixedSize()
        case .confirming:
            let whole = RestoreText.restoreCode(locale: locale)
            Button(isShort ? RestoreText.restoreCodeShort(locale: locale) : whole) {
                onRestore()
            }
            .buttonStyle(SupervisionDestructiveButtonStyle())
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
            .disabled(confirmation == nil || confirmation?.blockedReason != nil)
            .help(Text(verbatim: confirmation?.blockedReason ?? ""))
            // Return presses it while the strip has the keyboard.
            .supervisionFocusRing(
                isFocused: isFocused,
                cornerRadius: LimpidLayout.Supervision.buttonCornerRadius
            )
            .accessibilityLabel(Text(verbatim: whole))
            // Only why it can't restore: the strip's question, read just
            // before, already says what it restores.
            .accessibilityHint(Text(verbatim: confirmation?.blockedReason ?? ""))
            Button {
                onClose()
            } label: {
                Text("Cancel", comment: "Restore strip: closes the strip without restoring")
            }
            .buttonStyle(.supervisionSecondary)
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
        case .ended:
            Button {
                onClose()
            } label: {
                Text("Close", comment: "Restore strip: closes the strip after the restore stopped")
            }
            .buttonStyle(.supervisionSecondary)
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
        }
    }
}

/// A restore that may still be undone, as the decision bar shows it at
/// rest: "Restored to before T5 · Not reflected in the conversation"
/// and "Undo Restore".
struct RestoreRecordLine: View {
    let journal: RestoreJournal
    let handler: RestoreHandler
    @Environment(\.locale) private var locale

    var body: some View {
        // In the decision bar's foot bar, on the surface's own ground.
        SupervisionFootBar {
            HStack(spacing: LimpidLayout.Supervision.spaceS) {
                DecisionBarTag(text: RestoreText.stripTag(locale: locale), tone: .muted)
                RestoreRecordText(journal: journal, handler: handler, isOneLine: true)
                Spacer(minLength: LimpidLayout.Supervision.spaceS)
                RestoreUndoButton(journal: journal, handler: handler)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The record at the top of the changes panel, shown until the
/// restore is undone or work goes on from it.
struct RestoreRecordBox: View {
    let journal: RestoreJournal
    let handler: RestoreHandler
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LimpidLayout.Supervision.restoreRecordCornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: LimpidLayout.Supervision.restoreRecordSpacing) {
            RestoreRecordText(journal: journal, handler: handler, isOneLine: false)
            RestoreUndoButton(journal: journal, handler: handler)
        }
        .padding(LimpidLayout.Supervision.restoreRecordInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        // At the panel's opacity, so with transparency on it is not an
        // opaque patch (laid over the panel, a little denser).
        .background(shape.fill(SupervisionTokens.sidebar.color.opacity(surfaceOpacity)))
        .overlay(shape.strokeBorder(SupervisionTokens.line.color, lineWidth: 1))
        .padding(LimpidLayout.Supervision.restoreRecordMargins)
        .accessibilityElement(children: .contain)
    }
}

/// "Restored to before T5", then on one line "Not reflected in the
/// conversation" with what that means as its tooltip, or in the panel what
/// it means in full; and how "Undo Restore" fell short, if it did.
private struct RestoreRecordText: View {
    let journal: RestoreJournal
    let handler: RestoreHandler
    let isOneLine: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        let undoResult = handler.undoResult(journal.root)
        let layout = isOneLine
            ? AnyLayout(HStackLayout(spacing: LimpidLayout.Supervision.spaceSnug))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: LimpidLayout.Supervision.restoreRecordSpacing))
        layout {
            // A heading in the panel's box; in the bar, at rest, the line
            // reads evenly after its tag, as the bar's other rest lines do.
            Text(verbatim: RestoreText.record(journal, locale: locale))
                .font(.supervision(.row, weight: isOneLine ? .regular : .semibold))
                .foregroundStyle(isOneLine ? SupervisionTokens.muted.color : SupervisionTokens.text.color)
                .fixedSize()
            if isOneLine {
                Text(verbatim: "·")
                    .font(.supervision(.row))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .accessibilityHidden(true)
            }
            Text(verbatim: isOneLine ? RestoreText.notInConversation(locale: locale) : RestoreText.recordHelp(locale: locale))
                .font(.supervision(.row))
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(isOneLine ? 1 : nil)
                .fixedSize(horizontal: false, vertical: !isOneLine)
                .help(Text(verbatim: RestoreText.recordHelp(locale: locale)))
                .accessibilityHint(Text(verbatim: isOneLine ? RestoreText.recordHelp(locale: locale) : ""))
            if let aside = RestoreText.keptAsideSentence(journal.stage.keptAside, locale: locale) {
                if isOneLine {
                    Text(verbatim: "·")
                        .font(.supervision(.row))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .accessibilityHidden(true)
                }
                Text(verbatim: aside)
                    .font(.supervision(.row))
                    .foregroundStyle(SupervisionTokens.text.color)
                    .lineLimit(isOneLine ? 1 : nil)
                    // It names where the edits were kept.
                    .supervisionTruncation(.subject)
                    .help(Text(verbatim: aside))
            }
            if let undoResult {
                Text(verbatim: RestoreText.undoResult(undoResult, locale: locale))
                    .font(.supervision(.row, weight: .medium))
                    .foregroundStyle(SupervisionTokens.text.color)
                    .lineLimit(isOneLine ? 1 : nil)
                    .supervisionTruncation(.sentence)
                    .help(Text(verbatim: RestoreText.undoResult(undoResult, locale: locale)))
            }
        }
    }
}

/// "Undo Restore", from the record or the bar's "Done" line.
struct RestoreUndoButton: View {
    let journal: RestoreJournal
    let handler: RestoreHandler
    /// "Undo", in a decision bar too narrow for "Undo Restore"; VoiceOver
    /// still reads the whole.
    var isShort = false
    @Environment(\.locale) private var locale

    var body: some View {
        Button(isShort ? RestoreText.undoRestoreShort(locale: locale) : RestoreText.undoRestore(locale: locale)) {
            handler.undo(journal)
        }
        .accessibilityLabel(Text(verbatim: RestoreText.undoRestore(locale: locale)))
        // The look of the bar's Undo, which takes back a move the same way.
        .buttonStyle(.supervisionSecondary)
        // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
        .focusable(false)
        .disabled(handler.isBusy(journal.root))
        .help(Text(
            "Puts back the files as they were before the restore",
            comment: "Restore record: tooltip of Undo Restore"
        ))
    }
}

extension View {
    /// The handler a supervision window's bars and changes panel use for
    /// its restores. Its own modifier, so the window's long chain of
    /// modifiers stays within what the type checker takes.
    func restoreWindow(_ window: ProjectWindowState, state: AppState) -> some View {
        environment(\.restoreHandler, RestoreActions.handler(window: window, state: state))
    }
}
