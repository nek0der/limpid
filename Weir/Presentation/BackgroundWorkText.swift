// BackgroundWorkText.swift
// Weir — what an agent left running after its turn, in words.

import Foundation
import WeirDomain

/// The one sentence for work an agent left running when its turn ended
/// (`BackgroundWork`), which the decision bar says after a turn's receipt
/// and a session row says on its second line, so the two read alike.
enum BackgroundWorkText {
    /// "2 shells and 1 subagent still running in the background"; `nil`
    /// when nothing runs. Each kind with its count, in a fixed order, joined
    /// as the locale lists things.
    static func sentence(_ work: BackgroundWork, locale: Locale) -> String? {
        var kinds: [String] = []
        if work.shells > 0 {
            kinds.append(LocalizedStringResource(
                "\(work.shells) shells",
                comment: "Decision bar and session row: shells an agent left running in the background; argument: how many"
            ).resolved(in: locale))
        }
        if work.subagents > 0 {
            kinds.append(LocalizedStringResource(
                "\(work.subagents) subagents",
                comment: "Decision bar and session row: subagents an agent left running in the background; argument: how many"
            ).resolved(in: locale))
        }
        if work.others > 0 {
            kinds.append(LocalizedStringResource(
                "\(work.others) other items",
                comment: "Decision bar and session row: background work of a kind not named (a monitor, a remote agent); argument: how many"
            ).resolved(in: locale))
        }
        guard !kinds.isEmpty else { return nil }
        let list = kinds.formatted(.list(type: .and, width: .standard).locale(locale))
        return LocalizedStringResource(
            "\(list) still running in the background",
            comment: "Decision bar, after a turn's receipt, and session row: what an agent left running; argument: the kinds and counts"
        ).resolved(in: locale)
    }
}
