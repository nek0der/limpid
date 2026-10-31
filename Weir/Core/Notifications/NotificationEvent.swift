// NotificationEvent.swift
// Weir — what an agent's notification reported, kept as values so the history words it when it is shown.

import Foundation
import WeirDomain

/// What an agent's notification reported, as values rather than the
/// banner's sentence: which wait it was and what it named, the turn's
/// receipt and prompt, why the agent stopped. The history row words it in
/// the window's language when it draws (`NotificationHistoryRowText`), and
/// tells what happened from the detail under it, which the banner's
/// one-line body cannot.
///
/// Commands and OSC 9/777 alerts have none: their entry's own fields
/// (`exitCode`, `durationSeconds`, `title`, `body`) already are values.
enum NotificationEvent: Equatable, Sendable {
    /// Which wait an agent's prompt is in, as the attention list names it.
    enum Wait: String, Equatable, Sendable {
        case approval
        case question
        /// A wait we cannot name as either.
        case response
        /// The agent waits for the person to sign in again.
        case signIn
    }

    /// A finished turn's receipt: its number, what it changed, and its
    /// last check (`UnreadTurnRules.receipt(of:)`).
    struct Turn: Equatable, Sendable {
        let number: Int
        let changes: ChangeSummary
        let check: CheckSummary?
    }

    /// The agent waits on the person. `fact` is what the wait names: the
    /// command or file an approval waits on, else its tool; a question's
    /// words; the agent's own words for any other wait.
    case wait(agent: AgentKind, wait: Wait, fact: String?)
    /// A turn ended. `turn` is `nil` when no turn record stood for it;
    /// `prompt` is the person's words, which a prompt the harness wrote
    /// has none of (`promptKind` words it then, `TurnPromptText`). `reply`
    /// is what the agent said as it ended (`TurnSummary.reply`), `nil` when
    /// the turn kept none or the entry is from before it was kept.
    case turnFinished(agent: AgentKind, turn: Turn?, prompt: String?, promptKind: TurnPromptKind, reply: String?)
    /// The agent stopped, and why, as the provider said it.
    case stopped(agent: AgentKind, reason: String?)

    var agent: AgentKind {
        switch self {
        case let .wait(agent, _, _), let .turnFinished(agent, _, _, _, _), let .stopped(agent, _): agent
        }
    }

    /// The wait as the event records it: an approval's fact, a question's
    /// and any other wait's words.
    static func waiting(_ wait: PromptWait, agent: AgentKind) -> Self {
        switch wait {
        case let .approval(approval): .wait(agent: agent, wait: .approval, fact: approval.fact)
        case let .question(detail): .wait(agent: agent, wait: .question, fact: detail)
        case let .unclassified(detail): .wait(agent: agent, wait: .response, fact: detail)
        case .signIn: .wait(agent: agent, wait: .signIn, fact: nil)
        }
    }

    /// A finished turn, with the receipt of `turn` when a record stands
    /// for it; `head` is the prompt the projection quoted.
    static func finished(agent: AgentKind, turn: TurnSummary?, head: String?) -> Self {
        .turnFinished(
            agent: agent,
            turn: turn.map { Turn(number: $0.displayNumber, changes: $0.changes, check: $0.lastCheck) },
            prompt: head,
            promptKind: turn?.promptKind ?? .text,
            reply: turn?.reply
        )
    }
}

// MARK: - Coding

/// A `type` names the case, so a case a newer build adds fails to decode
/// here rather than reading as another; `NotificationEntry` then keeps the
/// entry without its event. An agent, a wait, or a prompt kind this build
/// does not know fails the same way: an event read as something it was not
/// would word the row wrongly, where none words it from the banner's text.
extension NotificationEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, agent, wait, fact, turn, prompt, promptKind, reply, reason
    }

    private enum Kind: String, Codable {
        case wait, turnFinished, stopped
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let agent = try container.decode(AgentKind.self, forKey: .agent)
        switch try container.decode(Kind.self, forKey: .type) {
        case .wait:
            let raw = try container.decode(String.self, forKey: .wait)
            guard let wait = Wait(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .wait, in: container, debugDescription: "unknown wait \(raw)")
            }
            self = try .wait(agent: agent, wait: wait, fact: container.decodeIfPresent(String.self, forKey: .fact))
        case .turnFinished:
            // `TurnPromptKind` reads a kind it does not know as the
            // person's words, which here would quote a harness's prompt.
            let raw = try container.decode(String.self, forKey: .promptKind)
            guard let promptKind = TurnPromptKind(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .promptKind, in: container, debugDescription: "unknown prompt kind \(raw)")
            }
            self = try .turnFinished(
                agent: agent,
                turn: container.decodeIfPresent(Turn.self, forKey: .turn),
                prompt: container.decodeIfPresent(String.self, forKey: .prompt),
                promptKind: promptKind,
                reply: container.decodeIfPresent(String.self, forKey: .reply)
            )
        case .stopped:
            self = try .stopped(agent: agent, reason: container.decodeIfPresent(String.self, forKey: .reason))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agent, forKey: .agent)
        switch self {
        case let .wait(_, wait, fact):
            try container.encode(Kind.wait, forKey: .type)
            try container.encode(wait.rawValue, forKey: .wait)
            try container.encodeIfPresent(fact, forKey: .fact)
        case let .turnFinished(_, turn, prompt, promptKind, reply):
            try container.encode(Kind.turnFinished, forKey: .type)
            try container.encodeIfPresent(turn, forKey: .turn)
            try container.encodeIfPresent(prompt, forKey: .prompt)
            try container.encode(promptKind.rawValue, forKey: .promptKind)
            try container.encodeIfPresent(reply, forKey: .reply)
        case let .stopped(_, reason):
            try container.encode(Kind.stopped, forKey: .type)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

/// The receipt in the history's own shape, apart from the hook's record
/// format that `ChangeSummary` and `CheckSummary` decode: the two can then
/// change apart. A change kind this build does not know fails the event,
/// as `ChangeSummary.unknown` would say "not yet known" of a turn that
/// ended long ago.
extension NotificationEvent.Turn: Codable {
    private enum CodingKeys: String, CodingKey {
        case number, changes, files, added, removed, reason, checkCommand, checkIsFiltered, checkExitCode, checkEarlierFailures
    }

    private enum Changes: String, Codable {
        case changed, unchanged, unavailable, pending, unknown
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        changes = switch try container.decode(Changes.self, forKey: .changes) {
        case .changed:
            try .changed(
                files: container.decode(Int.self, forKey: .files),
                added: container.decode(Int.self, forKey: .added),
                removed: container.decode(Int.self, forKey: .removed)
            )
        case .unchanged: .unchanged
        case .unavailable: try .unavailable(reason: container.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case .pending: .pending
        case .unknown: .unknown
        }
        check = try container.decodeIfPresent(String.self, forKey: .checkCommand).map { command in
            try CheckSummary(
                command: command,
                isFiltered: container.decodeIfPresent(Bool.self, forKey: .checkIsFiltered) ?? false,
                exitCode: container.decodeIfPresent(Int.self, forKey: .checkExitCode),
                // Absent in an entry from before it was kept.
                earlierFailures: container.decodeIfPresent(Int.self, forKey: .checkEarlierFailures) ?? 0
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        switch changes {
        case let .changed(files, added, removed):
            try container.encode(Changes.changed, forKey: .changes)
            try container.encode(files, forKey: .files)
            try container.encode(added, forKey: .added)
            try container.encode(removed, forKey: .removed)
        case .unchanged:
            try container.encode(Changes.unchanged, forKey: .changes)
        case let .unavailable(reason):
            try container.encode(Changes.unavailable, forKey: .changes)
            try container.encode(reason, forKey: .reason)
        case .pending:
            try container.encode(Changes.pending, forKey: .changes)
        case .unknown:
            try container.encode(Changes.unknown, forKey: .changes)
        }
        if let check {
            try container.encode(check.command, forKey: .checkCommand)
            try container.encode(check.isFiltered, forKey: .checkIsFiltered)
            try container.encodeIfPresent(check.exitCode, forKey: .checkExitCode)
            if check.earlierFailures > 0 {
                try container.encode(check.earlierFailures, forKey: .checkEarlierFailures)
            }
        }
    }
}
