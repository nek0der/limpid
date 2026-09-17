// TmuxMirrorActions+Reconnect.swift
// Limpid — connects mirror tabs that lost tmux to their session again, keeping what their panes show.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.mirror")

extension TmuxMirrorActions {
    // swiftlint:disable function_parameter_count
    /// Connect tab `tabID` to its tmux session again, together with every
    /// other tab of the same socket and session that can be (store key,
    /// stage 11 decision 5), over one control client. Only tabs that
    /// recorded the same server run are taken along: one checked server
    /// answers for them, and a tab restored from an earlier run of a server
    /// with the same session id must not be attached to this one.
    ///
    /// The tabs read `connecting` while the server is checked
    /// (`TmuxServerGeneration`). Then:
    /// - the recorded server, with the session: `otherClients` decides
    ///   whether to go on (a refusal puts every tab back as it was), and
    ///   each tab gets a new mirror on the session's connection. The new
    ///   mirror feeds the leaves' existing channels, so each surface keeps
    ///   its scrollback and is repainted in place. A tab whose window the
    ///   session no longer has closes with a notice (decision 3).
    /// - the recorded server, without the session: the tabs close with one
    ///   notice (decision 2).
    /// - another server, or no record of which one: `serverReplaced`. The
    ///   panes keep what they show as history (decisions 4 and 7).
    /// - no answer: `unreachable`.
    ///
    /// A new mirror rather than the old one resumed: a mirror's
    /// disconnection is final, and the store tells mirrors apart by
    /// identity, so nothing the old one still has in flight can reach the
    /// new one (decision 2 of the B4 plan).
    ///
    /// `otherClients` decides about the clients already attached: the menu
    /// passes `otherClientsGate`, which asks about other apps' clients, and
    /// the automatic reconnect passes `otherClientsGateWithoutAsking`
    /// (decision 10). Nil attaches beside every client.
    ///
    /// Returns the task that finishes the reconnect, or nil when the tab
    /// cannot be reconnected now.
    @discardableResult
    static func reconnect(
        tabID: UUID,
        session: WindowSession,
        store: TmuxConnectionStore,
        registry: any SurfaceViewProviding,
        secureInput: (any TmuxSecureInputSwitching)?,
        toastCenter: ToastCenter?,
        otherClients: OtherClientsGate?
    ) -> Task<Void, Never>? {
        guard let tmuxPath = store.tmuxExecutable,
              let tab = session.tab(tabID),
              let ref = mirrorRef(of: tab),
              store.canReconnect(tabID: tabID)
        else { return nil }
        let binding = ref.binding
        let key = TmuxConnectionStore.Key(binding)
        let generation = TmuxServerGeneration.recorded(in: binding)
        let tabs = session.tabs.filter { other in
            guard let otherRef = mirrorRef(of: other) else { return false }
            return TmuxConnectionStore.Key(otherRef.binding) == key
                && TmuxServerGeneration.recorded(in: otherRef.binding) == generation
                && store.canReconnect(tabID: other.id)
        }
        var previous: [UUID: TmuxTabConnection?] = [:]
        for other in tabs {
            previous[other.id] = store.tabConnections[other.id]
            store.setTabConnection(.connecting, tabID: other.id)
        }
        let context = MirrorContext(session: session, store: store, registry: registry, secureInput: secureInput, toastCenter: toastCenter)
        let target = TmuxMirrorTarget(
            binding: binding,
            windowID: ref.windowID,
            windowName: store.mirror(for: tabID)?.windowName ?? tab.title,
            activePaneID: ref.paneID,
            serverVersion: nil
        )
        let tabIDs = Set(previous.keys)
        return Task {
            let verdict = await TmuxServerGeneration.check(tmuxPath: tmuxPath, binding: binding)
            log.notice("reconnect session=\(binding.sessionID, privacy: .public): \(String(describing: verdict), privacy: .public)")
            switch verdict {
            case .matches(hasSession: true):
                if let otherClients, await !otherClients(target) {
                    for tabID in waiting(tabIDs, store: store, session: session) {
                        store.setTabConnection(previous[tabID] ?? nil, tabID: tabID)
                    }
                    return
                }
                attachAgain(waiting(tabIDs, store: store, session: session), binding: binding, context: context)
            case .matches(hasSession: false):
                let closing = waiting(tabIDs, store: store, session: session)
                guard !closing.isEmpty else { return }
                for tabID in closing {
                    TabActions.closeTab(session, registry: registry, tabID: tabID, confirm: false, isReopenable: false)
                }
                store.onNotice?(TmuxConnectionStore.sessionEndedNotice(sessionName: binding.sessionName))
            case .replaced, .unrecorded:
                for tabID in waiting(tabIDs, store: store, session: session) {
                    store.setTabConnection(.serverReplaced, tabID: tabID)
                }
            case .unreachable:
                for tabID in waiting(tabIDs, store: store, session: session) {
                    store.setTabConnection(.unreachable, tabID: tabID)
                }
            }
        }
    }

    // swiftlint:enable function_parameter_count

    // MARK: - Automatic reconnect

    /// Connect every mirror tab of `context.session` again, once, after the
    /// session was restored at launch (stage 11 decision 6). Not from
    /// `reconcile`: that runs on every change to the tab list, and a tab the
    /// user has not asked for must not be attached again each time.
    @discardableResult
    static func reconnectAtLaunch(context: MirrorContext, limpidTTYs: Set<String>? = nil) -> [Task<Void, Never>] {
        let tabIDs = context.session.tabs.filter { mirrorRef(of: $0) != nil }.map(\.id)
        return reconnectWithoutAsking(tabIDs, context: context, limpidTTYs: limpidTTYs)
    }

    /// ⌘⇧T: bring the most recently closed tab back, and connect it again
    /// at once when it is a mirror tab, as a restored one is (stage 11
    /// decision 6). Without a store the tab comes back unconnected.
    static func reopenClosedTab(_ session: WindowSession, specificID: UUID? = nil, context: MirrorContext?) {
        guard let tabID = TabActions.reopenClosedTab(session, specificID: specificID),
              let context,
              let tab = session.tab(tabID),
              mirrorRef(of: tab) != nil
        else { return }
        reconnectWithoutAsking([tabID], context: context)
    }

    /// Reconnect `tabIDs` with no dialog (decision 10): nobody asked for
    /// this connection at this moment, so a question about other apps'
    /// clients would come out of nowhere. Tabs of one socket, session, and
    /// server run are taken along by the first of them, so the later calls
    /// for those tabs return nil and add nothing.
    @discardableResult
    static func reconnectWithoutAsking(
        _ tabIDs: [UUID],
        context: MirrorContext,
        limpidTTYs: Set<String>? = nil
    ) -> [Task<Void, Never>] {
        guard let tmuxPath = context.store.tmuxExecutable else { return [] }
        let gate = otherClientsGateWithoutAsking(
            tmuxPath: tmuxPath,
            session: context.session,
            store: context.store,
            registry: context.registry,
            limpidTTYs: limpidTTYs
        )
        return tabIDs.compactMap { tabID in
            reconnect(
                tabID: tabID,
                session: context.session,
                store: context.store,
                registry: context.registry,
                secureInput: context.secureInput,
                toastCenter: context.toastCenter,
                otherClients: gate
            )
        }
    }

    /// The other-clients gate with nobody to ask. A client running in a
    /// Limpid pane is still detached, as it is when the user opens a
    /// window: the pane would otherwise hold the same session a second
    /// time. Another app's client is left attached and the tab opens.
    ///
    /// The Limpid panes are those whose tty can be read when the gate runs.
    /// That misses none that matter: a pane's pty exists exactly while its
    /// surface does, and a surface is registered before it is created, so
    /// a pane without a readable tty has no process that could have
    /// attached. A pane whose shell attaches later is not seen, and waiting
    /// would not see it either.
    static func otherClientsGateWithoutAsking(
        tmuxPath: String,
        session: WindowSession,
        store: TmuxConnectionStore,
        registry: any SurfaceViewProviding,
        limpidTTYs: Set<String>? = nil
    ) -> OtherClientsGate {
        otherClientsGate(
            tmuxPath: tmuxPath,
            session: session,
            store: store,
            registry: registry,
            limpidTTYs: limpidTTYs,
            confirm: { _, _ in .openWithoutDetaching }
        )
    }

    /// The tmux side of a mirror tab: every leaf of one shows a pane of the
    /// same window of the same session, so any leaf's reference names it.
    static func mirrorRef(of tab: Tab) -> TmuxPaneRef? {
        guard tab.kind == .tmuxMirror else { return nil }
        return tab.paneSources.values.lazy.compactMap { source -> TmuxPaneRef? in
            if case let .tmux(ref) = source {
                return ref
            }
            return nil
        }.first
    }

    /// The tabs a reconnect still speaks for after a wait: a tab the user
    /// closed meanwhile is gone from the session, and its state from the
    /// store.
    private static func waiting(
        _ tabIDs: Set<UUID>,
        store: TmuxConnectionStore,
        session: WindowSession
    ) -> [UUID] {
        session.tabs.map(\.id).filter { tabIDs.contains($0) && store.tabConnections[$0] == .connecting }
    }

    /// Mirror each tab over the session's connection. A tab whose window
    /// another tab already shows again stays disconnected: tmux feeds each
    /// pane to one sink.
    private static func attachAgain(_ tabIDs: [UUID], binding: TmuxBinding, context: MirrorContext) {
        guard !tabIDs.isEmpty else { return }
        let store = context.store
        let connection: TmuxServerConnection
        do {
            connection = try store.connectionForReconnect(to: binding)
        } catch {
            log.error("cannot reconnect session=\(binding.sessionID, privacy: .public): \(String(describing: error), privacy: .public)")
            for tabID in tabIDs {
                store.setTabConnection(.disconnected, tabID: tabID)
            }
            return
        }
        var started: [TmuxWindowMirror] = []
        for tabID in tabIDs {
            guard let tab = context.session.tab(tabID), let ref = mirrorRef(of: tab) else { continue }
            if store.liveMirror(showing: ref.windowID, of: binding) != nil {
                store.setTabConnection(.disconnected, tabID: tabID)
                continue
            }
            let mirror = makeMirror(
                tabID: tabID,
                windowID: ref.windowID,
                names: (binding.sessionName, store.mirror(for: tabID)?.windowName ?? tab.title),
                connection: connection,
                context: context
            )
            store.register(mirror)
            mirror.start()
            started.append(mirror)
        }
        store.closeMirrorsOfMissingWindows(started, on: connection)
    }
}

extension TmuxMirrorActions.MirrorContext {
    /// The context of an entry point that may run without tmux support,
    /// where there is no store; Secure Input goes through the registry's.
    @MainActor
    init?(session: WindowSession, store: TmuxConnectionStore?, registry: any SurfaceViewProviding, toastCenter: ToastCenter?) {
        guard let store else { return nil }
        self.init(session: session, store: store, registry: registry, secureInput: registry.secureInput, toastCenter: toastCenter)
    }
}
