// ApprovalResolution.swift
// Weir — the decision the controller sends back for an approval request.

import Foundation

/// What the controller sends back for one request. How the broker reads
/// and writes it, and how large it may be, is the wire's
/// (`ApprovalResolution+Wire.swift`), so this stays a plain value.
enum ApprovalResolution: Equatable, Sendable {
    case allowOnce
    case deny
    /// No decision: the provider's own prompt takes over. Also used to
    /// release a request the terminal already answered.
    case delegate
    case answer([String: String])

    var answers: [String: String]? {
        if case let .answer(answers) = self {
            return answers
        }
        return nil
    }
}
