// BackgroundWork.swift
// Weir — the work an agent left running in the background when its turn ended.

import Foundation

/// How many tasks of each kind an agent still had running when its turn
/// ended: shells started to run in the background, subagents launched to
/// run on their own, and kinds we do not name (Claude's monitors, remote
/// agents). Counts rather than the tasks themselves, as the rules report
/// them (`BackgroundWork` in `weir-agent-model`): a task's own words are
/// already in the agent's terminal.
///
/// The run stays finished while these run. When one ends on its own, the
/// agent starts a turn of its own, and that turn's end reports what is left.
/// One the person stops from Claude's task list starts no turn, so the count
/// keeps it until the next prompt.
package struct BackgroundWork: Codable, Equatable, Hashable, Sendable {
    package var shells: Int
    package var subagents: Int
    /// Tasks of a kind the interface does not name.
    package var others: Int

    /// Whether no task is counted.
    package var isEmpty: Bool {
        shells == 0 && subagents == 0 && others == 0
    }

    package init(shells: Int = 0, subagents: Int = 0, others: Int = 0) {
        self.shells = shells
        self.subagents = subagents
        self.others = others
    }

    private enum CodingKeys: String, CodingKey {
        case shells, subagents, others
    }

    /// A missing count is zero, as the projection spells the counts (it
    /// leaves a kind with none out); the synthesized decoder would require
    /// all three, which only the badge this app persists always writes.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shells = try container.decodeIfPresent(Int.self, forKey: .shells) ?? 0
        subagents = try container.decodeIfPresent(Int.self, forKey: .subagents) ?? 0
        others = try container.decodeIfPresent(Int.self, forKey: .others) ?? 0
    }
}
