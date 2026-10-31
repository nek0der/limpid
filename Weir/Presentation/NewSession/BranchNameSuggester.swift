// BranchNameSuggester.swift
// Weir — the branch name a new worktree gets while its field is empty.

import Foundation

/// The branch a new worktree gets while its field is empty:
/// `task/MMDD-n`, numbered so two made one after the other never collide.
/// The sheet takes no instruction to name it from any more; renaming the
/// branch once its work has a name is the person's.
enum BranchNameSuggester {
    /// The suggested name. `isTaken` says whether a name is a branch
    /// already, or would put the worktree in a folder that exists.
    static func suggest(today: Date, calendar: Calendar = .current, isTaken: (String) -> Bool) -> String {
        let parts = calendar.dateComponents([.month, .day], from: today)
        let day = String(format: "%02d%02d", parts.month ?? 1, parts.day ?? 1)
        var number = 1
        // Bounded so a check that says every name is taken cannot loop
        // forever; git then reports the clash.
        while number < 1000, isTaken("task/\(day)-\(number)") {
            number += 1
        }
        return "task/\(day)-\(number)"
    }

    /// Whether git takes `name` as a new branch's: the rules of
    /// `git check-ref-format --branch` that a person can break by typing.
    /// A name that passes here and fails in git still reports git's own
    /// words.
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), name != "@", name != "HEAD"
        else { return false }
        for forbidden in ["..", "//", "@{", "/."] where name.contains(forbidden) {
            return false
        }
        if name.split(separator: "/").contains(where: { $0.hasSuffix(".lock") }) {
            return false
        }
        if name.hasPrefix(".") {
            return false
        }
        return !name.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || " ~^:?*[\\".unicodeScalars.contains(scalar)
        }
    }

    /// The folder name a branch's worktree gets: `/` would make nested
    /// folders. The worktree hook uses the same rule for a worktree an agent
    /// asks for (`worktree_path` in `rust/weir-agent-hook/src/worktree.rs`);
    /// the two sides check it against
    /// `rust/fixtures/contract/shared-values.json`.
    static func folderLeaf(of branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }
}
