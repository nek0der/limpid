// MenuBarApprovalRule.swift
// Weir — what the menu bar may do with a request: allow or deny it there, or leave it to Weir.

import Foundation

/// What the menu bar may do with a request. It allows or denies only
/// a shell command shown whole and not high-impact, and only while the
/// request still takes a decision; anything else is answered in Weir,
/// where the card (the row's Answer…) shows its context, or in the
/// terminal it was handed to (the row itself, which goes to its pane).
/// "Always allow" is offered nowhere.
package enum MenuBarApprovalRule {
    /// The longest command the menu shows whole, and so may allow.
    static let maxCommandLength = 60

    package enum Offer: Equatable {
        /// "Allow Once" and "Deny".
        case allowOrDeny
        /// A high-impact command (`HighImpactCommand`): answered in Weir.
        case highImpact
        /// Longer than the menu shows whole, or on more than one line:
        /// answered in Weir.
        case tooLong
        /// Short, but with characters that would show other than what runs
        /// (`Visibility.hiddenCharacters`): answered in Weir. Apart from
        /// `tooLong` so the note does not call a short command long.
        case notShownWhole
        /// A tool that runs no shell command (an edit, a subagent, an MCP
        /// tool): what it does is read on the card.
        case notACommand
        /// Claude's question: answered on the card (Answer…).
        case answerInWeir
        /// Codex's question, answered in its TUI, and a request no longer
        /// taking a decision: the menu only goes to its pane.
        case openPane
        /// The person's answer is on its way.
        case sending
        /// Answered already, here or elsewhere.
        case answered
        /// Handed to the agent's own prompt: answered there.
        case handedToTerminal
        /// Timed out: answered in the terminal.
        case timedOut
    }

    /// What the menu offers for a request. `command` is the shell command
    /// an approval runs; `nil` for any other tool and for a question.
    package static func offer(isQuestion: Bool, supportsNativeAnswer: Bool, command: String?, state: ApprovalRequestState) -> Offer {
        switch state {
        case .handedToTerminal:
            return .handedToTerminal
        case .timedOut:
            return .timedOut
        case .sending:
            return .sending
        case .answered:
            return .answered
        case .held, .sendFailed, .withdrawn, .unknownResult:
            break
        }
        // A request no longer taking a decision (withdrawn, its result not
        // known) is only opened, a question as much as a command.
        guard state.acceptsDecision else { return .openPane }
        if isQuestion {
            return supportsNativeAnswer ? .answerInWeir : .openPane
        }
        // An empty command runs nothing the menu could show, and has no
        // characters to hide: it reads as a tool that runs no command.
        guard let command, !command.isEmpty else { return .notACommand }
        switch visibility(of: command) {
        case .whole: break
        case .tooLong: return .tooLong
        case .hiddenCharacters: return .notShownWhole
        }
        return HighImpactCommand.isHighImpact(command) ? .highImpact : .allowOrDeny
    }

    /// How much of a command the menu can show as it will run.
    package enum Visibility: Equatable {
        /// Short, on one line, and every character shows as itself.
        case whole
        /// Longer than `maxCommandLength`, or on more than one line.
        case tooLong
        /// Empty, or with a character that would make what is read differ
        /// from what runs (a tab, a direction override, a zero-width or
        /// other ignorable character, a private-use or unassigned one).
        case hiddenCharacters
    }

    /// Whether the menu shows `command` as it will run (`Visibility`). A
    /// line break is a control character too, but a command on several
    /// lines reads as a long one, so it is told apart first.
    package static func visibility(of command: String) -> Visibility {
        let scalars = command.unicodeScalars
        let breaksLine = scalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .lineSeparator, .paragraphSeparator: true
            default: ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}"].contains(scalar)
            }
        }
        if command.count > maxCommandLength || breaksLine {
            return .tooLong
        }
        let hidesCharacters = command.isEmpty || scalars.contains { scalar in
            if scalar.properties.isDefaultIgnorableCodePoint {
                return true
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .unassigned, .surrogate: return true
            default: return false
            }
        }
        return hidesCharacters ? .hiddenCharacters : .whole
    }
}
