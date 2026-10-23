// ReviewTabActions+Handler.swift
// Limpid — the review tab's actions, bound to one window for the tab's views.

import Foundation

extension ReviewTabActions {
    /// The handler the tab's views reach these through, for `window`.
    static func handler(window: ProjectWindowState, stores: ReviewTabStores, paneVisibility: PaneVisibilityReporter) -> ReviewTabHandler {
        ReviewTabHandler(
            windowID: window.id,
            context: { [window, stores] tab in context(of: tab, window: window, stores: stores) },
            select: { [window, stores] option, conversation in select(option, conversation: conversation, window: window, stores: stores) },
            conversations: { [window, stores] tab in conversations(of: tab, window: window, stores: stores) },
            loadFileTagPaths: { [window, stores] tab in await loadFileTagPaths(of: tab, window: window, stores: stores) },
            fileTags: { [window, stores] tab in fileTags(of: tab, window: window, stores: stores) },
            addFollowingTurns: { [window, stores] in addFollowingTurns(window: window, stores: stores) },
            markViewed: { [window, stores] in markViewed(window: window, stores: stores, paneVisibility: paneVisibility) },
            isShowingItsScope: { [window] tab in isShowingItsScope(tab, window: window) },
            primaryKey: { [window, stores] in primaryKey(window: window, stores: stores, paneVisibility: paneVisibility) },
            noteBandShown: { [window] action, opening in noteBandShown(action, of: opening, window: window) },
            refreshPathsOutsideTurns: { [window, stores] in await refreshPathsOutsideTurns(window: window, stores: stores) },
            pathsOutsideTurns: { [stores] tab in pathsOutsideTurns(of: tab, stores: stores) },
            close: { [window, stores] in closeAsked(window: window, stores: stores, paneVisibility: paneVisibility) },
            destinations: { [window, stores] tab, agents in destinations(of: tab, agents: agents, window: window, stores: stores) },
            destinationPanes: { [window, stores] tab in destinationPanes(of: tab, window: window, stores: stores) },
            isDestinationOpen: { [stores] tab in isDestinationOpen(tab, session: stores.session) },
            chooseDestination: { [window] paneID in chooseDestination(paneID, window: window) },
            startPane: { [window, stores] paneID in
                await startPane(paneID, window: window, stores: stores, paneVisibility: paneVisibility)
            },
            closeAfterInsert: { [window, stores] inserted in
                // An agent the session's tab does not list (one run inside
                // tmux) is still the one the pane's bar shows.
                let agent = inserted.agent ?? stores.attention.headerRuntime(inPane: inserted.paneID)?.conversation?.provider
                return closeAfterInsert(
                    ReviewTabInserted(paneID: inserted.paneID, agent: agent, opening: inserted.opening, selection: inserted.selection),
                    window: window,
                    session: stores.session,
                    registry: stores.registry,
                    paneVisibility: paneVisibility,
                    barItems: stores.attentionQueue.queue.items(inPane: inserted.paneID)
                )
            },
            hunkActions: { [window, stores] hunks, locale in
                ReviewHunkDiscardActions.actions(hunks, window: window, stores: stores.hunks, locale: locale)
            },
            hunkDiscardKey: { [stores] tab in ReviewHunkDiscardActions.preparationKey(tab: tab, stores: stores.hunks) },
            prepareHunkDiscards: { [window, stores] tab in await ReviewHunkDiscardActions.prepare(
                tab: tab,
                window: window,
                stores: stores.hunks
            ) },
            discardHunk: { [window, stores] tab, file, header, locale in
                ReviewHunkDiscardActions.discard(
                    .init(tab: tab, file: file, header: header),
                    window: window,
                    stores: stores.hunks,
                    locale: locale
                )
            },
            undoDiscard: { [window, stores] tab, file, header, locale in
                ReviewHunkDiscardActions.undo(
                    .init(tab: tab, file: file, header: header),
                    window: window,
                    stores: stores.hunks,
                    locale: locale
                )
            }
        )
    }
}
