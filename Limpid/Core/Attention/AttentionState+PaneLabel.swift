// AttentionState+PaneLabel.swift
// Limpid — what a pane is called, read from the session and the runs in it,
// for every surface that names a pane.
//
// `PaneHeaderRules.label` decides the order the sources win in; this file
// gathers those sources for one pane. The pane header and the prompt cache
// panel both read it, so the panel names a pane exactly as its header does.

import Foundation

@MainActor
extension AttentionState {
    /// The label `paneID`'s header shows: the name the user gave the pane,
    /// else its agent's conversation title, else its directory's last
    /// component, with the directory beside it. `locale` names a pane that
    /// has none of those; callers pass the window's, so the fallback
    /// switches with the display language.
    func paneHeaderLabel(paneID: UUID, in session: WindowSession, locale: Locale) -> PaneHeaderLabel {
        let tab = session.tab(containing: paneID)
        let agent = headerRuntime(inPane: paneID).map { runtime in
            PaneHeaderAgent(
                providerName: AgentProviderRegistry.displayName(for: runtime.kind),
                title: PaneHeaderRules.agentTitle(
                    for: runtime.badge,
                    hasSessionTitles: AgentProviderRegistry.hasSessionTitles(runtime.kind)
                )
            )
        }
        // The pane's own OSC 7 directory first. Until the shell reports one
        // (a restored pane, a shell without integration) the tab's latest
        // directory stands in, then the one the tab opened in.
        let directory = session.workingDirectory(paneID: paneID)
            ?? tab?.pwd
            ?? tab?.workingDirectory
        return PaneHeaderRules.label(
            customName: session.paneState(paneID).name,
            agent: agent,
            workingDirectory: directory,
            fallbackName: LocalizedStringResource("Terminal").resolved(in: locale)
        )
    }
}
