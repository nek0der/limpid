// AttentionState+Runtimes.swift
// Weir — invocation-scoped attention independent of client attachments.

import Foundation
import WeirDomain

extension AttentionState {
    /// In `AgentKind`'s order rather than the dictionary's, which can differ
    /// from one launch to the next: which agent a row at rest speaks for and
    /// which pane it opens are read from the first of these.
    var allRuntimes: [AgentRuntimePresentation] {
        AgentKind.allCases.flatMap { runtimesByKind[$0] ?? [] }
    }

    /// Replaces one provider's runtimes. The marks are not trimmed here: the
    /// projection returns the set that still applies with every pass, and the
    /// adapter writes that back through `replaceMarks`, so trimming twice
    /// would be two rules for one thing.
    ///
    /// Skipped when nothing changed. `@Observable` reports every write as a
    /// change whether or not the value moved, and every sidebar and tab
    /// column row derives its badge from this dictionary, so a pass that
    /// found the same runtimes as the last one would otherwise re-render all
    /// of them. The key is still created on the first write: an empty list
    /// and a provider that has never been projected are different answers
    /// to the review surface.
    func replaceRuntimes(_ runtimes: [AgentRuntimePresentation], kind: AgentKind) {
        guard runtimesByKind[kind] != runtimes else { return }
        runtimesByKind[kind] = runtimes
        refreshPromptCacheWindows()
    }

    /// Replaces the marks with the set the projection says still applies.
    /// Guarded for the same reason as `replaceRuntimes`: the attention list,
    /// the badges, and the notification history all read the marks.
    func replaceMarks(viewed: [String: String]) {
        if viewedRuntimeTokens != viewed {
            viewedRuntimeTokens = viewed
        }
    }

    /// A run whose turns are recorded is viewed once they are read: looking
    /// at a turn that changed files does not read it. Any other run is
    /// viewed by its episode's mark.
    func isViewed(_ runtime: AgentRuntimePresentation) -> Bool {
        if let decided = turnReadDecision(runtime) {
            return decided
        }
        return viewedRuntimeTokens[runtime.id] == runtime.attentionEventToken
    }

    func markVisibleRuntimesViewed(paneID: UUID) {
        var changed = false
        // Focusing the outer surface does not mean we saw a background tmux
        // pane: only the active window's active pane shows the agent.
        for runtime in allRuntimes where runtime.activeAttachmentPaneIDs.contains(paneID) && runtime.badge.state == .finished {
            // The episode's own mark, whatever the turns say: only it is
            // written here.
            if viewedRuntimeTokens[runtime.id] != runtime.attentionEventToken {
                viewedRuntimeTokens[runtime.id] = runtime.attentionEventToken
                changed = true
            }
        }
        if changed {
            onRuntimeAttentionChanged?()
        }
    }

    /// Acknowledge finished runtime episodes recorded as read in notification
    /// history. Matching both identifiers prevents an old notification from
    /// acknowledging a later turn in the same invocation.
    func markFinishedRuntimesViewed(matching eventTokensByRuntimeID: [String: Set<String>]) {
        var changed = false
        for runtime in allRuntimes where runtime.badge.state == .finished {
            guard eventTokensByRuntimeID[runtime.id]?.contains(runtime.attentionEventToken) == true,
                  viewedRuntimeTokens[runtime.id] != runtime.attentionEventToken
            else { continue }
            viewedRuntimeTokens[runtime.id] = runtime.attentionEventToken
            changed = true
        }
        if changed {
            onRuntimeAttentionChanged?()
        }
    }
}
