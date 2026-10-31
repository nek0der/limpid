// WorkspaceSession+ConversationTabNames.swift
// Weir — keeps the name the person gave a tab for the conversation it stood for, past the tab.

import Foundation

extension WorkspaceSession {
    /// Names a tab as the person typed it (`Tab.rename`), and keeps the
    /// name for the conversation the tab's title stands for then, or lets
    /// it go when they clear the name: an empty name gives the tab back to
    /// its terminal's title, and the conversation back to its agent's. Kept
    /// only here, when the person names the tab, never handed on to a
    /// conversation that later takes the tab's title (a split, a tab
    /// reused): that one is called by the tab's name while it runs there,
    /// and two conversations side by side would otherwise share it for
    /// good. Which
    /// conversation that is comes from `runtimes` by the rule the pane
    /// strip and the changes panel read (`ConversationTabs`), so a tab
    /// whose agent has ended names no conversation here either.
    func renameTab(_ id: UUID, to name: String, runtimes: [AgentRuntimePresentation]) {
        update(id) { $0.rename(name) }
        guard let tab = tab(id),
              let conversation = ConversationTabs(tabs: [tab], runtimes: runtimes).conversations(of: id)?.titled
        else { return }
        let kept = name.isEmpty ? nil : name
        if conversationTabNames[conversation] != kept {
            conversationTabNames[conversation] = kept
        }
    }
}
