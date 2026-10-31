// SurfaceView+AgentCommand.swift
// Weir — types an agent's own slash command at its prompt and submits it,
// and keeps track of whether the prompt may hold input the user has not sent.

import AppKit
import GhosttyKit

extension SurfaceView: AgentCommandTyping {
    /// The foreground process group's leader on this surface's pty, as
    /// libghostty reads it from the side of the pty it owns, named by the
    /// path it was started from (`ProcessNames`).
    var foregroundProcessName: String? {
        guard let pid = foregroundProcessID else { return nil }
        return ProcessNames.name(of: pid)
    }

    var foregroundProcessID: pid_t? {
        guard let surface else { return nil }
        return GhosttyFFI.surfaceForegroundPID(surface)
    }

    /// The names of the processes in the foreground process group, its
    /// leader first (`ProcessNames.foregroundGroupNames`).
    var foregroundGroupProcessNames: [String] {
        guard let leader = foregroundProcessID else { return [] }
        return ProcessNames.foregroundGroupNames(leader: leader)
    }

    /// The arguments the foreground group's leader was started with, after
    /// its own name (a shell at its prompt has none, `-l`, or what Ghostty's
    /// shell integration adds); `nil` when the kernel will not say.
    var foregroundLeaderArguments: [String]? {
        guard let leader = foregroundProcessID, leader > 0 else { return nil }
        return ProcessNames.processArguments(of: leader).map(\.arguments)
    }

    /// Types `command` as keystrokes, then schedules the Return that runs
    /// it, which any input of the person's before it lands cancels.
    ///
    /// Not a paste. An agent composer folds a bracketed paste into the
    /// message as literal text, so a pasted `/compact` is sent to the model
    /// rather than run as a command; and an unbracketed one would meet the
    /// paste confirmation `clipboard-paste-protection` forces on. The text
    /// therefore goes through `commitText(_:)`, which writes it to the pty
    /// as typed input that no keybinding can intercept.
    ///
    /// The Return is scheduled a moment later rather than sent in the same
    /// write (`PendingCommandSubmit`). Arriving
    /// together, the agent can read the whole chunk as one burst of input
    /// and treat it as pasted; apart, the command line is complete and its
    /// suggestion list settled when the key that runs it arrives.
    func typeAgentCommand(_ command: String) -> Bool {
        // Typed, not pasted: a control character is a key to the line
        // editor, and DEL is a backspace that could take a quote away from
        // a path in the command.
        guard surface != nil,
              !command.isEmpty,
              !command.unicodeScalars.contains(where: \.isTypedControl)
        else { return false }
        // Typed through `commitText` and `sendReturnKey` directly, which
        // `noteKeyInput(_:)` and `noteTextInput()` do not see: our own
        // command is no draft of the user's, and leaving the two marks as
        // they were means it cannot block the next answer. The callers
        // checked the draft mark of the job in front before typing.
        noteTypedOwnCommand(command)
        commitText(command)
        // Any input of the person's before it lands takes the Return away
        // (`noteKeyInput(_:)`, `noteTextInput()`): after a ⌃C and ↑ at a
        // shell, it would run the history line they brought back.
        commandSubmit.schedule(after: Self.commandSubmitDelay) { [weak self] in
            guard let self, let surface = self.surface else { return }
            self.sendReturnKey(to: surface)
        }
        return true
    }

    /// How long after the command's text the Return that runs it follows.
    /// Long enough for the agent to read the text as typed input rather
    /// than one pasted burst, and for its suggestion list to settle; short
    /// enough that the two still read as one action.
    static let commandSubmitDelay: Duration = .milliseconds(120)

    // MARK: - Unsent input

    /// Who a draft was typed to. A draft belongs to the prompt it was typed
    /// at: an agent that exits takes its prompt, and what was typed there,
    /// along, so a key left in Claude's TUI does not count as text at the
    /// shell after.
    enum DraftOwner: Equatable {
        case process(pid_t)
        /// The job in front could not be read; the draft is kept.
        case unknown
    }

    var hasUnsubmittedInput: Bool {
        switch draftOwner {
        case nil: false
        case .unknown: true
        case let .process(pid): pid == foregroundProcessID
        }
    }

    /// Records whether a draft waits at the job in front: `isDraft` is true
    /// when text reached it, false when it was sent or dropped.
    func noteDraft(_ isDraft: Bool) {
        draftOwner = isDraft ? foregroundProcessID.map(DraftOwner.process) ?? .unknown : nil
    }

    /// What one key press does to an agent's prompt, as far as the terminal
    /// can tell without reading the screen.
    enum PromptInputEffect: Equatable {
        /// It never reached the prompt: a shortcut that acts on the app.
        case none
        /// It may have left text, or a picker, at the prompt.
        case draft
        /// It sent or discarded what was there.
        case submit
    }

    /// Classifies a key press. Conservative: anything that is not a plain
    /// Return or Ctrl+C counts as a draft, because a wrong "draft" only
    /// disables the cache panel's buttons while a wrong "submit" lets a
    /// command join the user's text. Shift-Return and Option-Return insert
    /// a line break in an agent's composer rather than sending, so they
    /// are drafts too. Command shortcuts act on the app, except ⌘V, which
    /// pastes into the prompt.
    nonisolated static func promptInputEffect(
        key: NamedKey?,
        charactersIgnoringModifiers characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> PromptInputEffect {
        let held = modifiers.intersection([.command, .control, .option, .shift])
        if held.contains(.command) {
            return characters?.lowercased() == "v" ? .draft : .none
        }
        if key == .return, held.isEmpty {
            return .submit
        }
        if held == [.control], characters?.lowercased() == "c" {
            return .submit
        }
        return .draft
    }

    /// Records a key press that reached this terminal.
    func noteKeyInput(_ event: NSEvent) {
        switch Self.promptInputEffect(
            key: event.namedKey,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags
        ) {
        case .none:
            return
        case .draft:
            noteDraft(true)
        case .submit:
            noteDraft(false)
        }
        commandSubmit.cancel()
        lastKeyInputAt = Date()
    }

    /// Records a clipboard read libghostty answered for this terminal,
    /// which is how every paste arrives. A listing asks only which types are
    /// on the clipboard and hands over no text, so it marks nothing.
    func noteClipboardRead(isListing: Bool) {
        guard !isListing else { return }
        noteTextInput()
    }

    /// Records text that reached this terminal without a key press of its
    /// own: a paste (marked where every paste lands, in `GhosttyApp`'s
    /// clipboard read), dropped file paths, Dictation, or the character
    /// viewer.
    func noteTextInput() {
        noteDraft(true)
        commandSubmit.cancel()
        lastKeyInputAt = Date()
    }

    /// Types `body`, the initial command (`scheduleInitialCommandIfNeeded`),
    /// and Return into the terminal, and tells `onInitialCommandTyped`;
    /// nothing at all when the terminal is gone. Split from the wait so a
    /// test can see that a pane with no terminal reports nothing typed.
    func typeInitialCommand(_ body: String) {
        guard let surface else {
            // No terminal to type into: nothing staged is coming.
            stagedCommand = nil
            return
        }
        body.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
        sendReturnKey(to: surface)
        stagedCommand?.typedAt = .now
        // Typed once: a surface made again for this view (Retry) must
        // not run it a second time, nor report it again.
        initialCommand = nil
        let typed = onInitialCommandTyped
        onInitialCommandTyped = nil
        typed?(Date())
    }
}

/// This holds the Return `typeAgentCommand(_:)` sends a moment after the
/// command's text, so the person's own input meanwhile can take it away. The
/// Return was typed for the line as Weir left it; once they pressed a
/// key there, the line is theirs, and the Return would run whatever it
/// holds by then.
@MainActor
final class PendingCommandSubmit {
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    /// `sleep` is the wait before the Return, a test's own so that it can
    /// act inside the wait rather than race a clock.
    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Runs `submit` after `delay`, unless `cancel()` comes first. A second
    /// command replaces the first one's Return, which would otherwise land
    /// in the middle of the second's text.
    func schedule(after delay: Duration, _ submit: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor [sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            // We check after the wait too: a cancel can come between the
            // wait's end and this task running again.
            guard !Task.isCancelled else { return }
            submit()
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Returns once the Return scheduled last was sent or dropped.
    func settled() async {
        await task?.value
    }
}
