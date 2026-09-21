// TmuxMirrorActions.swift
// Limpid — opens a tab that mirrors one tmux window, and the actions on its panes that need more than the mirror.

import AppKit
import OSLog

private let log = Logger.limpid("tmux.mirror")

@MainActor
enum TmuxMirrorActions {
    /// Open `target` as a new tab in the active scope. The tab starts with
    /// the window's active pane; the first `%layout-change` after
    /// `refresh-client -C` fills in the others.
    ///
    /// The tab is written before the connection is taken: every write to
    /// `session.tabs` has the store release connections no mirror uses,
    /// and the mirror can only be registered once its tab id exists. A
    /// client that cannot be started, or that tmux refuses later, closes
    /// that tab again with one notice (`TmuxConnectionStore`): nothing
    /// would ever fill it.
    ///
    /// A window a live tab already mirrors is not opened twice; that tab is
    /// brought forward instead, because each tmux pane feeds one sink.
    ///
    /// `after` puts the tab beside a tab of the user's, in that tab's
    /// container, for a window opened from one (⌃⌘T): the new window is
    /// next to it in tmux too. Without it the tab opens where a new tab
    /// opens, in the container the user is looking at (D7).
    @discardableResult
    static func open(
        _ target: TmuxMirrorTarget,
        session: WindowSession,
        store: TmuxConnectionStore,
        after anchorTabID: UUID? = nil
    ) -> Bool {
        if let existing = store.liveMirror(showing: target.windowID, of: target.binding) {
            session.setActiveTab(existing.tabID)
            return true
        }
        let anchor = anchorTabID.flatMap { session.tab($0) }
        let tab = anchor.map { session.openTab(container: $0.container, after: $0.id) }
            ?? session.openTabInActiveScope()
        return startMirror(target, inNewTab: tab, session: session, store: store) { $0.title = target.displayName }
    }

    /// Turn `tab`, just opened with one leaf, into a mirror of `target` and
    /// connect it: the part of opening every entry shares. `describe` sets
    /// what differs between entries (the title, the origin) in the same
    /// write that makes the tab a mirror, so nothing observes it half made.
    private static func startMirror(
        _ target: TmuxMirrorTarget,
        inNewTab tab: Tab,
        session: WindowSession,
        store: TmuxConnectionStore,
        describe: (inout Tab) -> Void
    ) -> Bool {
        guard let paneID = tab.splitTree.allLeafIDs().first else { return false }
        let ref = TmuxPaneRef(binding: target.binding, windowID: target.windowID, paneID: target.activePaneID)
        session.update(tab.id) { t in
            t.kind = .tmuxMirror
            t.paneSources[paneID] = .tmux(ref)
            describe(&t)
        }
        let connection: TmuxSessionConnection
        do {
            connection = try store.connection(for: target.binding)
        } catch {
            log.error("cannot mirror \(target.displayName, privacy: .private): \(String(describing: error), privacy: .public)")
            // Named before the tab goes: `describe` has run, so the record
            // already says whose mirror this is, and an agent's is called
            // after its agent rather than after the session id we gave it.
            let name = TmuxConnectionStore.noticeName(of: session.tab(tab.id), tmuxName: target.displayName)
            TabActions.closeTab(session, registry: store.registry, tabID: tab.id, confirm: false, isReopenable: false)
            // No tmux spoke here, so there is no reason of tmux's to show;
            // the log keeps the system's.
            store.onNotice?(TmuxConnectionStore.openFailureNotice(name: name, reason: nil))
            return false
        }
        let mirror = store.makeMirror(
            tabID: tab.id,
            windowID: target.windowID,
            binding: target.binding,
            names: (target.binding.sessionName, target.windowName),
            connection: connection,
            isNewTab: true,
            session: session
        )
        store.register(mirror)
        mirror.start()
        return true
    }

    /// Open the tab a shim asked for when it started an agent in our tmux
    /// server (design §2.2 and §6). Returns false when nothing was opened:
    /// a tab already holds the request's leaf, or the mirror could not be
    /// started (which closes the tab again with a notice, as `open` does).
    ///
    /// - The tab's only leaf takes the request's `leafID`, the
    ///   `LIMPID_PANE_ID` the agent runs under, so its records, badges, and
    ///   approval cards name this leaf with nothing to translate.
    /// - It goes right after the tab the agent was started from, in that
    ///   tab's container, whichever container the user is looking at. When
    ///   that tab is gone, it goes to the end of the active container.
    /// - It becomes the active tab only when the tab it was started from is
    ///   the active one (design §5 decision 4): a command started in a tab the user has
    ///   since left must not pull them back. The session is the one every
    ///   window of the app shows, so there is no other window's selection to
    ///   keep apart (§6 decision 13). `isUserAsked` overrides both: a tab the
    ///   user asked for a moment ago (`openDetachedAgentRun`) opens where a
    ///   new tab opens and takes the focus.
    /// - Other clients are not asked about: the session was created a moment
    ///   ago, detached, by the shim. The server's version is not checked
    ///   here either, as none is for a tab `break-pane` opens: the shim is
    ///   only told to host when the tmux it runs passed the launch probe
    ///   (`AgentTmuxSupport`).
    @discardableResult
    static func openAgentMirror(
        _ request: AgentMirrorRequest,
        session: WindowSession,
        store: TmuxConnectionStore,
        isUserAsked: Bool = false
    ) -> Bool {
        guard session.tab(containing: request.leafID) == nil else { return false }
        let launchTab = isUserAsked ? nil : session.tab(containing: request.launchPaneID)
        let workingDirectory = (launchTab?.pwd ?? launchTab?.workingDirectory).map { URL(fileURLWithPath: $0) }
        let name = AgentProviderRegistry.displayName(for: request.provider)
        let tab = session.openTab(
            container: launchTab?.container ?? session.activeContainerID,
            title: name,
            workingDirectory: workingDirectory,
            paneID: request.leafID,
            after: launchTab?.id,
            activates: isUserAsked || (launchTab.map { $0.id == session.activeTabID } ?? false)
        )
        // The window's name is tmux's to give; until the mirror asks, the
        // notices name the window after the agent.
        let target = TmuxMirrorTarget(
            binding: request.binding,
            windowID: request.windowID,
            windowName: name,
            activePaneID: request.paneID,
            serverVersion: nil
        )
        return startMirror(target, inNewTab: tab, session: session, store: store) { t in
            t.mirrorOrigin = .agent
            t.mirroredAgent = request.provider
        }
    }

    /// What the user chose about clients another app has attached.
    enum OtherClientsChoice: Equatable {
        case detachAndOpen
        case openWithoutDetaching
        case cancel
    }

    /// Open `target` the way the palette does (design D7). The clients
    /// already attached to its session are found first. Those running in a
    /// Limpid pane are detached, which returns the pane to its shell with
    /// its scrollback; for any other app's, the user chooses, because tmux
    /// fits a window to every client showing it and one left attached can
    /// shrink the tab's picture.
    ///
    /// A window a tab already shows is brought forward at once, with
    /// nothing asked of tmux. `limpidTTYs` and `confirm` default to this
    /// app's panes and an alert; tests pass their own.
    ///
    /// Returns the task that finishes opening, or nil when the tab was
    /// handled without waiting.
    @discardableResult
    static func openFromPalette(
        _ target: TmuxMirrorTarget,
        session: WindowSession,
        store: TmuxConnectionStore,
        limpidTTYs: Set<String>? = nil,
        confirm: @escaping @MainActor (TmuxMirrorTarget, [TmuxAttachedClient]) -> OtherClientsChoice = askAboutOtherClients
    ) -> Task<Void, Never>? {
        let finish: () -> Void = {
            open(target, session: session, store: store)
        }
        // `open` makes the same check; answering here keeps a window that is
        // already on screen from waiting on a child process.
        guard store.liveMirror(showing: target.windowID, of: target.binding) == nil,
              let tmuxPath = store.tmuxExecutable
        else {
            finish()
            return nil
        }
        let admit = otherClientsGate(
            tmuxPath: tmuxPath,
            session: session,
            store: store,
            limpidTTYs: limpidTTYs,
            confirm: confirm
        )
        return Task {
            guard await admit(target) else { return }
            finish()
        }
    }

    /// Decides, before a client attaches to `target`'s session, whether it
    /// goes ahead. Returns false only when the user cancelled.
    typealias OtherClientsGate = @MainActor (_ target: TmuxMirrorTarget) async -> Bool

    /// The gate that deals with the clients already attached (design D7):
    /// those running in a Limpid pane are detached without asking, and for
    /// any other app's the user chooses through `confirm`. The Limpid panes
    /// and this app's own control clients are read when the gate runs, so
    /// a gate made early still sees the clients of that moment.
    static func otherClientsGate(
        tmuxPath: String,
        session: WindowSession,
        store: TmuxConnectionStore,
        limpidTTYs: Set<String>? = nil,
        confirm: @escaping @MainActor (TmuxMirrorTarget, [TmuxAttachedClient]) -> OtherClientsChoice = askAboutOtherClients
    ) -> OtherClientsGate {
        { [weak session, weak store] target in
            guard let session, let store else { return false }
            let binding = target.binding
            let found = await findClientsDetachingLimpidPanes(
                tmuxPath: tmuxPath,
                binding: binding,
                ownControlPIDs: store.ownControlPIDs,
                limpidTTYs: limpidTTYs ?? paneTTYs(session: session, registry: store.registry)
            )
            // A pane of ours was attached to this session and has just been
            // detached, which drops it back to its shell with nothing on
            // screen to say why. It is the pane's own scrollback it returns
            // to, so the news is the whole remedy.
            if !found.limpidPanes.isEmpty {
                store.onNotice?(Self.paneDetachedNotice(name: target.displayName))
            }
            guard !found.otherApps.isEmpty else { return true }
            switch confirm(target, found.otherApps) {
            case .cancel:
                return false
            case .openWithoutDetaching:
                return true
            case .detachAndOpen:
                await detach(found.otherApps, tmuxPath: tmuxPath, socketPath: binding.socketPath)
                return true
            }
        }
    }

    /// What the user reads when opening a mirror detached a client of
    /// Limpid's own (design D5). `name` is `session:window`.
    static func paneDetachedNotice(name: String) -> String {
        String(localized: "“\(name)” now shows in a Limpid tab, so this pane was detached from it.")
    }

    /// The alert behind `openFromPalette`'s `confirm`.
    static func askAboutOtherClients(_ target: TmuxMirrorTarget, _: [TmuxAttachedClient]) -> OtherClientsChoice {
        let name = target.binding.sessionName
        let choice = LimpidConfirm.runThreeWay(
            title: String(localized: "“\(name)” is already attached elsewhere"),
            message: String(localized: """
            tmux fits a window to every client that shows it. While the others stay attached, \
            this tab may show the window smaller. Detaching them ends what they show of this session.
            """),
            primaryLabel: String(localized: "Detach and Open"),
            alternateLabel: String(localized: "Open Without Detaching")
        )
        switch choice {
        case .primary: return .detachAndOpen
        case .alternate: return .openWithoutDetaching
        case .cancel: return .cancel
        }
    }

    private static func paneTTYs(session: WindowSession, registry: any SurfaceViewProviding) -> Set<String> {
        Set(session.tabs.flatMap { $0.splitTree.allLeafIDs() }.compactMap { registry.view(for: $0)?.ttyName })
    }

    /// Dispatch rather than a detached task: these block on child
    /// processes, and a blocked cooperative-pool thread starves the
    /// runtime. The closures are formed in these nonisolated functions so
    /// Dispatch never runs one that carries main-actor isolation.
    private nonisolated static func findClientsDetachingLimpidPanes(
        tmuxPath: String,
        binding: TmuxBinding,
        ownControlPIDs: Set<pid_t>,
        limpidTTYs: Set<String>
    ) async -> TmuxAttachedClients {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let clients = TmuxAttachedClients.probe(tmuxPath: tmuxPath, binding: binding) ?? []
                let found = TmuxAttachedClients.classify(clients, ownControlPIDs: ownControlPIDs, limpidTTYs: limpidTTYs)
                TmuxAttachedClients.detach(found.limpidPanes, tmuxPath: tmuxPath, socketPath: binding.socketPath)
                continuation.resume(returning: found)
            }
        }
    }

    private nonisolated static func detach(_ clients: [TmuxAttachedClient], tmuxPath: String, socketPath: String) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                TmuxAttachedClients.detach(clients, tmuxPath: tmuxPath, socketPath: socketPath)
                continuation.resume()
            }
        }
    }

    /// Move a pane into a tab of its own. For a mirror tab this is
    /// `break-pane`: tmux gives the pane a new window, and a mirror tab is
    /// opened on that window once tmux reports its id. Anything else goes
    /// the ordinary way.
    static func movePaneToNewTab(
        _ session: WindowSession,
        paneID: UUID,
        store: TmuxConnectionStore?,
        toastCenter: ToastCenter?
    ) {
        guard let sourceTab = session.tab(containing: paneID) else { return }
        guard sourceTab.kind == .tmuxMirror else {
            TabActions.movePaneToNewTab(session, paneID: paneID)
            return
        }
        guard sourceTab.splitTree.allLeafIDs().count > 1,
              let store,
              let mirror = PaneActions.liveMirrorOrNotify(for: sourceTab, in: store, toastCenter: toastCenter),
              case let .tmux(ref) = sourceTab.ioSource(for: paneID)
        else { return }
        mirror.breakPane(paneID: paneID) { window in
            guard let window else { return }
            mirror.removeMovedPane(paneID)
            let target = TmuxMirrorTarget(
                binding: ref.binding,
                windowID: window.windowID,
                windowName: window.windowName,
                activePaneID: ref.paneID,
                serverVersion: mirror.connection.version
            )
            open(target, session: session, store: store)
        }
    }

    /// Merge a pane into another tab. Two mirror tabs on the same tmux
    /// session use `join-pane`; a tmux pane cannot leave tmux, and a mirror
    /// tab stays pure (design §1), so every other pairing that involves a
    /// mirror is refused with a word to the user (`acceptsPane`). Two
    /// mirror tabs of which either is disconnected cannot ask tmux, and say
    /// so.
    static func mergePaneIntoTab(
        _ session: WindowSession,
        paneID: UUID,
        into targetTabID: UUID,
        store: TmuxConnectionStore?,
        toastCenter: ToastCenter?
    ) {
        guard let sourceTab = session.tab(containing: paneID),
              let targetTab = session.tab(targetTabID),
              sourceTab.id != targetTabID
        else { return }
        guard acceptsPane(from: sourceTab, into: targetTab) else {
            // The refusal speaks of what the user moved: an ordinary pane
            // was refused by the tab it was dropped on, a tmux pane by
            // tmux.
            let message = sourceTab.kind == .tmuxMirror
                ? String(localized: "A tmux pane can only move between windows of its own session")
                : String(localized: "Only panes of the same tmux session can move into this tab")
            toastCenter?.show(ToastItem(message: message, undo: nil))
            return
        }
        guard sourceTab.kind == .tmuxMirror else {
            TabActions.mergePaneIntoTab(session, paneID: paneID, into: targetTabID)
            return
        }
        guard let source = store?.liveMirror(for: sourceTab.id), let target = store?.liveMirror(for: targetTabID) else {
            toastCenter?.show(ToastItem(message: String(localized: "Not connected to tmux"), undo: nil))
            return
        }
        source.joinPane(paneID: paneID, into: target.windowID)
    }

    /// Whether a pane of `sourceTab` may land in `targetTab`, as far as the
    /// two tabs say: an ordinary pane goes to a tab that takes foreign
    /// panes, and a tmux pane only to a mirror tab of its own tmux session.
    /// The tab row a pane is dragged over lights up only when this holds,
    /// and the drop decides by it too. Whether both mirrors are connected
    /// is left to the drop, which says so; the tabs cannot tell.
    ///
    /// An agent's tab takes no pane and gives none: its one pane is the
    /// agent's, under the leaf id the agent's records name, and any other
    /// pane of the agent's session inherited that same id from the
    /// session's environment.
    static func acceptsPane(from sourceTab: Tab, into targetTab: Tab) -> Bool {
        guard sourceTab.kind == .tmuxMirror else { return targetTab.capabilities.canAcceptForeignPane }
        guard sourceTab.mirrorOrigin == .user, targetTab.mirrorOrigin == .user else { return false }
        guard let source = mirrorRef(of: sourceTab), let target = mirrorRef(of: targetTab) else { return false }
        return TmuxConnectionStore.Key(source.binding) == TmuxConnectionStore.Key(target.binding)
    }

    /// Paste the clipboard into a mirror pane through tmux. A paste that
    /// could run lines as commands asks first, on the sheet an ordinary
    /// pane uses; the rule is stricter here (`TmuxPasteBuffer`). Without a
    /// sheet to ask on, such a paste is not sent.
    static func paste(
        into paneID: UUID,
        view: SurfaceView,
        session: WindowSession,
        store: TmuxConnectionStore?,
        toastCenter: ToastCenter?,
        pasteboard: NSPasteboard = .general,
        confirmation: ClipboardConfirmationCoordinator? = ClipboardConfirmationCoordinator.shared
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard text.utf8.count <= TmuxPasteBuffer.byteLimit else {
            toastCenter?.show(ToastItem(message: String(localized: "The clipboard is too large to paste into a tmux pane"), undo: nil))
            return
        }
        paste(text, into: paneID, view: view, session: session, store: store, toastCenter: toastCenter, confirmation: confirmation)
    }

    // swiftlint:disable function_parameter_count
    /// Type the shell-quoted paths of files dropped on a mirror pane, the
    /// same text an ordinary pane types (`FileDropText`), as a paste
    /// through tmux. A path list stays far below `TmuxPasteBuffer.byteLimit`,
    /// so only the clipboard is checked against it. A path with a line
    /// break in it asks first, as the same paste from the clipboard would.
    static func dropFiles(
        _ fileURLs: [URL],
        into paneID: UUID,
        view: SurfaceView?,
        session: WindowSession,
        store: TmuxConnectionStore?,
        toastCenter: ToastCenter?,
        confirmation: ClipboardConfirmationCoordinator? = ClipboardConfirmationCoordinator.shared
    ) {
        guard !fileURLs.isEmpty else { return }
        let text = FileDropText.text(for: fileURLs)
        paste(text, into: paneID, view: view, session: session, store: store, toastCenter: toastCenter, confirmation: confirmation)
    }

    /// Hand review's text to a mirror pane, as a tmux paste.
    ///
    /// The same route and the same confirmation rule as any other paste into
    /// a mirror; what it adds is the answer review is owed. A paste that goes
    /// straight through has landed, one the sheet takes over is answered by
    /// the sheet, and every other way out reports a delivery that did not
    /// happen, so the comments do not stay marked as sent.
    static func deliverReview(
        _ text: String,
        receipt: ReviewPasteReceipt?,
        into paneID: UUID,
        view: SurfaceView?,
        session: WindowSession,
        store: TmuxConnectionStore?,
        toastCenter: ToastCenter?,
        confirmation: ClipboardConfirmationCoordinator? = ClipboardConfirmationCoordinator.shared
    ) {
        let delivery = ReviewPasteDelivery(receipt: receipt)
        defer { delivery.failIfUnsettled() }
        guard let tab = session.tab(containing: paneID),
              let mirror = PaneActions.liveMirrorOrNotify(for: tab, in: store, toastCenter: toastCenter)
        else { return }
        guard TmuxPasteBuffer.needsConfirmation(text) else {
            mirror.paste(text, paneID: paneID)
            delivery.landed()
            return
        }
        // The sheet is anchored to the pane's view; without one there is
        // nowhere to ask, and the text is not sent.
        guard let view, let confirmation else { return }
        confirmation.enqueueMirrorPaste(
            contents: text,
            view: view,
            receipt: delivery.handedOn()
        ) { [weak mirror] in
            mirror?.paste(text, paneID: paneID)
        }
    }

    private static func paste(
        _ text: String,
        into paneID: UUID,
        view: SurfaceView?,
        session: WindowSession,
        store: TmuxConnectionStore?,
        toastCenter: ToastCenter?,
        confirmation: ClipboardConfirmationCoordinator?
    ) {
        guard let tab = session.tab(containing: paneID),
              let mirror = PaneActions.liveMirrorOrNotify(for: tab, in: store, toastCenter: toastCenter)
        else { return }
        guard TmuxPasteBuffer.needsConfirmation(text) else {
            mirror.paste(text, paneID: paneID)
            return
        }
        // The sheet is anchored to the pane's view; without one there is
        // nowhere to ask, and the text is not sent.
        guard let view else { return }
        confirmation?.enqueueMirrorPaste(contents: text, view: view) { [weak mirror] in
            mirror?.paste(text, paneID: paneID)
        }
    }

    // swiftlint:enable function_parameter_count
}
