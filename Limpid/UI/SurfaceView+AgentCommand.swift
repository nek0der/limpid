// SurfaceView+AgentCommand.swift
// Limpid — types an agent's own slash command at its prompt and submits it,
// and keeps track of whether the prompt may hold input the user has not sent.

import AppKit
import GhosttyKit

extension SurfaceView: AgentCommandTyping {
    /// The foreground process group's leader on this surface's pty, as
    /// libghostty reads it from the side of the pty it owns, named by the
    /// path it was started from.
    ///
    /// Not the kernel's accounting name: Claude Code's native installer
    /// starts `~/.local/bin/claude`, a link to a file named after the
    /// version, and the accounting name is that version (`2.1.292`). The
    /// start path is what a provider's declared process names match, and
    /// what the hook's own ancestor walk compares, through `ps -o comm`.
    var foregroundProcessName: String? {
        guard let pid = foregroundProcessID else { return nil }
        return Self.executableName(of: pid) ?? TmuxPanePresence.processName(of: pid)
    }

    var foregroundProcessID: pid_t? {
        guard let surface else { return nil }
        return GhosttyFFI.surfaceForegroundPID(surface)
    }

    /// The last component of the path `pid` was started from, read from the
    /// head of its argument area (`KERN_PROCARGS2`: the argument count, then
    /// that path), or `nil` when the kernel will not say.
    private nonisolated static func executableName(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        // The second call can report less than the first sized for.
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        let path = buffer[MemoryLayout<Int32>.size..<size].prefix { $0 != 0 }
        guard !path.isEmpty, let text = String(bytes: path, encoding: .utf8) else { return nil }
        return (text as NSString).lastPathComponent
    }

    /// Types `command` as keystrokes, then presses Return.
    ///
    /// Not a paste. An agent composer folds a bracketed paste into the
    /// message as literal text, so a pasted `/compact` is sent to the model
    /// rather than run as a command; and an unbracketed one would meet the
    /// paste confirmation `clipboard-paste-protection` forces on. The text
    /// therefore goes through `commitText(_:)`, which writes it to the pty
    /// as typed input that no keybinding can intercept.
    ///
    /// Return follows a moment later rather than in the same write. Arriving
    /// together, the agent can read the whole chunk as one burst of input
    /// and treat it as pasted; apart, the command line is complete and its
    /// suggestion list settled when the key that runs it arrives.
    func typeAgentCommand(_ command: String) -> Bool {
        guard surface != nil,
              !command.isEmpty,
              !command.unicodeScalars.contains(where: { $0.value < 0x20 })
        else { return false }
        // Typed through `commitText` and `sendReturnKey` directly, which
        // `noteKeyInput(_:)` and `noteTextInput()` do not see: our own
        // command is no draft of the user's, and leaving the two marks as
        // they were means it cannot block the next answer. Neither needs
        // resetting afterwards, since both had to be clear for us to type.
        commitText(command)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.commandSubmitDelay)
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
            hasUnsubmittedInput = true
        case .submit:
            hasUnsubmittedInput = false
        }
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
        hasUnsubmittedInput = true
        lastKeyInputAt = Date()
    }
}
