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
    func paneHeaderLabel(paneID: UUID, in session: WorkspaceSession, locale: Locale) -> PaneHeaderLabel {
        let tab = session.tab(containing: paneID)
        // We keep conversation selection stable for restore and Changes,
        // but settings describe the agent the terminal currently shows.
        // We retain a warning from any visible split, even when another
        // split has focus. Its model and provider identify the same agent.
        let runtimes = allRuntimes.filter { $0.paneIDs.contains(paneID) }
        let facts = runtimes.map { runtime in
            let location = runtime.tmuxLocations[paneID]
            return PaneHeaderOwnershipRules.Run(
                id: runtime.id,
                runID: runtime.runID,
                parentRunID: runtime.badge.parentRunID,
                endpoint: location.map {
                    PaneHeaderOwnershipRules.Endpoint(
                        socketPath: $0.socketPath,
                        serverPID: $0.serverPID,
                        serverStartedAt: $0.recordedServerStart,
                        paneID: $0.paneID
                    )
                },
                isKnown: runtime.badge.state != .unknown,
                isVisible: location?.isVisible ?? location?.isActive ?? true,
                isActive: location?.isActive ?? true,
                runsWithoutAsking: runtime.badge.agentPermissionMode?.runsWithoutAsking == true,
                updatedAt: runtime.badge.updatedAt,
                sessionStartedAt: runtime.badge.sessionStartedAt,
                launchOrder: runtime.badge.runLaunchOrder,
                observedOrder: runtime.badge.runObservedOrder
            )
        }
        let selection = PaneHeaderOwnershipRules.select(from: facts)
        let settingsRuntime = runtimes.first { $0.id == selection.ownerID }
        // The run the header speaks for, else the agent the pane's tab
        // wears for it (`Tab.agentKind(inPane:)`): one in front before its
        // record, or a restored run that has not reported since. Only the
        // badge and the provider's name: neither has a conversation title,
        // a model, or a mode to give, and `headerRuntime` stays the one that
        // names a conversation, which code restore and the changes panel
        // match on.
        let runtime = headerRuntime(inPane: paneID)
        let agent = runtime.map { runtime in
            let kind = settingsRuntime?.kind ?? runtime.kind
            return PaneHeaderAgent(
                kind: kind,
                providerName: AgentProviderRegistry.displayName(for: kind),
                title: PaneHeaderRules.agentTitle(for: runtime.badge),
                model: settingsRuntime?.badge.model,
                permissionMode: settingsRuntime?.badge.agentPermissionMode
            )
        } ?? tab?.agentKind(inPane: paneID).map { kind in
            PaneHeaderAgent(kind: kind, providerName: AgentProviderRegistry.displayName(for: kind), title: nil)
        }
        // The pane's own OSC 7 directory first. Until the shell reports one
        // (a restored pane, a shell without integration) the tab's latest
        // directory stands in, then the one the tab opened in.
        let directory = session.workingDirectory(paneID: paneID)
            ?? tab?.pwd
            ?? tab?.workingDirectory
        var label = PaneHeaderRules.label(
            customName: session.paneState(paneID).name,
            agent: agent,
            workingDirectory: directory,
            fallbackName: LocalizedStringResource("Terminal").resolved(in: locale)
        )
        // The run the badge is: its color and hover must not name another's.
        label.conversation = settingsRuntime?.conversation ?? runtime?.conversation
        if selection.isAmbiguous {
            label.model = nil
            label.permissionMode = nil
            label.settingsAreAmbiguous = true
        }
        return label
    }

}
