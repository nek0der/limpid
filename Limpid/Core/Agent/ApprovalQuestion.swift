// ApprovalQuestion.swift
// Limpid — provider-neutral question attached to an approval request.

import Foundation

/// One question the agent wants answered. Mirrors `ApprovalQuestion` in the
/// Rust model; the snapshot carries it under `request.questions`.
struct ApprovalQuestion: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let label: String
        let description: String?
    }

    let header: String?
    let prompt: String
    let options: [Option]
    let isMultiSelect: Bool

    /// Decodes the snapshot array. Entries without a prompt are dropped: the
    /// Rust side never emits them, and a card cannot ask an empty question.
    static func decode(_ value: Any?) -> [ApprovalQuestion] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let prompt = entry["prompt"] as? String else { return nil }
            let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                guard let label = option["label"] as? String else { return nil }
                return Option(label: label, description: option["description"] as? String)
            }
            return ApprovalQuestion(
                header: entry["header"] as? String,
                prompt: prompt,
                options: options,
                isMultiSelect: entry["multi_select"] as? Bool ?? false
            )
        }
    }
}
