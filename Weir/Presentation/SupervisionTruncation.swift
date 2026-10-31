// SupervisionTruncation.swift
// Weir — the one rule for which end of a line the supervision window gives up when it does not fit.

import Foundation
import WeirDomain

/// What a line holds, which decides where it is cut when it is too long,
/// so the same information loses the same part wherever it is shown — a
/// branch, say, in the title bar and in all projects, or an approval's file
/// in the sidebar and in the decision bar. The supervision window's titles,
/// names, paths, branches, and facts name their kind here, and the view cuts them at
/// `edge` (`supervisionTruncation(_:)`). Two lines keep a mode of their
/// own, each saying why where it is set: the review's destination menu,
/// whose one string holds a pane's name and what runs there, and the menu
/// bar's list, which is outside the window.
enum SupervisionTruncation: Equatable, Sendable {
    /// Prose: an instruction, a summary, a question, a reason, a message.
    /// It is read from its start, so its end goes.
    case sentence
    /// A name: a project's, a workspace's, a tab's the person gave or a
    /// program set. Its start is what it is known by.
    case name
    /// A location stated as a fact: a project's folder, a pane's folder on
    /// the status band, a file in the review. The middle goes, so the start
    /// still says where and the end which file.
    case path
    /// A fact that names a file, a folder, a branch, or a command, alone
    /// or after the words that lead into it ("Write: /Users/…/notes.txt",
    /// "Waiting for approval: npm test", "Creates feat/login from main"),
    /// and an agent's own words at its prompt, which often end in the file
    /// they are about. The middle goes, so the verb and what it names both
    /// stay.
    case subject
    /// A branch, alone or after its project ("alpha / feature/…-chatbot").
    /// Branches share their prefixes (`feature/`) and differ at their
    /// ends, so the middle goes.
    case branch
    /// A path of places read from the right ("weir › main › Claude"):
    /// its start goes, so the place nearest the person stays.
    case breadcrumb
    /// A path that stands as a label, told apart from its neighbors by its
    /// end: a tab's title a shell set to its folder ("…/projects/alpha"),
    /// a pane's folder beside its name, a file's folder under its name.
    /// The start is the part they share, so it goes.
    case pathTitle

    /// Which end of a line gives way. Kept apart from SwiftUI's own type so
    /// the rule can be read and tested without a view.
    enum Edge: Equatable, Sendable {
        case head
        case middle
        case tail
    }

    var edge: Edge {
        switch self {
        case .sentence, .name: .tail
        case .path, .subject, .branch: .middle
        case .breadcrumb, .pathTitle: .head
        }
    }

    /// `text` with its middle replaced by an ellipsis once it is longer
    /// than `limit` characters, keeping a little more of its end than of
    /// its start: for a name set into a sentence that must not be cut
    /// itself, so the cut is made in the name, by count, before the line is
    /// laid out. A name in a monospaced face measures by its characters.
    static func middle(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let kept = limit - 1
        let head = kept / 2
        let tail = kept - head
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    /// `text` cut to its first `limit` characters and an ellipsis once it
    /// is longer, read from its start as a name is: for a line an AppKit
    /// menu draws, which cannot cut a line itself and widens the whole menu
    /// to its longest item, so the cut is made by count before the menu is
    /// built.
    static func end(_ text: String, keeping limit: Int) -> String {
        guard text.count > limit, limit > 0 else { return text }
        // A cut that falls after a space would leave "Fix the …".
        let kept = String(text.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return kept + "…"
    }

    /// How many characters of a name a menu shows: a conversation's title
    /// can be a whole first prompt or a long rename, which would otherwise
    /// make every item of its menu as wide.
    static let menuNameLimit = 32

    /// A name as an AppKit menu shows it (`menuNameLimit`); its tooltip and
    /// VoiceOver keep it whole.
    static func menuName(_ name: String) -> String {
        end(name, keeping: menuNameLimit)
    }

    // MARK: - Titles

    /// A title that may be a path (a terminal tab's, which the person, the
    /// program, or the shell's OSC 2 sets): a path-shaped one is cut at its
    /// head, anything else as a name.
    static func title(_ title: String) -> SupervisionTruncation {
        isPathTitle(title) ? .pathTitle : .name
    }

    /// Whether `title` reads as a path, as a shell names its tab by its
    /// folder: three shells in one project then differ only at the end. It
    /// does when its first word is one ("/usr/local", "~", "~/notes",
    /// "…/repos/alpha"), or when what follows a prompt's "user@host: " is.
    /// A first word under the root needs a second "/", so a slash command
    /// ("/init", "/review-pr 123") stays a name; so do a command line
    /// ("vim ~/notes") and a name ("Claude").
    static func isPathTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if startsWithPath(trimmed) {
            return true
        }
        guard let separator = trimmed.range(of: ": ") else { return false }
        return startsWithPath(trimmed[separator.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    private static func startsWithPath(_ text: String) -> Bool {
        guard let word = text.split(whereSeparator: \.isWhitespace).first.map(String.init) else { return false }
        if word == "~" || word.hasPrefix("~/") || word.hasPrefix("…/") || word.hasPrefix(".../") {
            return true
        }
        return word.hasPrefix("/") && word.dropFirst().contains("/")
    }

    // MARK: - Facts

    /// A sidebar row's fact, and the facts read from it (all projects'
    /// cards): what names a file or a command is a subject, the rest prose.
    /// An approval names its command, a running agent its tool and the
    /// tool's argument ("Bash: swift test"), and a wait at the prompt what
    /// `wait(_:)` says; a question is read from its start.
    static func fact(_ fact: SessionRowFact.Fact) -> SupervisionTruncation {
        switch fact {
        case .approval(.some), .running(.some):
            .subject
        case let .prompt(wait):
            self.wait(wait)
        case .question, .approval(nil), .running(nil), .stopped, .unread, .compacting,
             .pullRequest, .uncommitted, .commits, .workingAfterTurn, .noChanges, .idle, .unknown:
            .sentence
        }
    }

    /// A wait at the agent's prompt, as its line words it: an approval that
    /// names its file or command, and the agent's own words when we cannot
    /// name the wait, keep both ends; a question, and a wait stated only by
    /// its state ("Needs approval"), read from their start.
    static func wait(_ wait: PromptWait) -> SupervisionTruncation {
        switch wait {
        case let .approval(approval): approval.fact == nil ? .sentence : .subject
        case .unclassified(.some): .subject
        case .question, .signIn, .unclassified(nil): .sentence
        }
    }
}
