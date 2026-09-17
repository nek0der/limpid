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
    @discardableResult
    static func open(
        _ target: TmuxMirrorTarget,
        session: WindowSession,
        store: TmuxConnectionStore,
        registry: any SurfaceViewProviding,
        secureInput: SecureInputManager?,
        toastCenter: ToastCenter? = nil
    ) -> Bool {
        if let existing = store.liveMirror(showing: target.windowID, of: target.binding) {
            session.setActiveTab(existing.tabID)
            return true
        }
        let tab = session.openTabInActiveScope()
        guard let paneID = tab.splitTree.allLeafIDs().first else { return false }
        let ref = TmuxPaneRef(binding: target.binding, windowID: target.windowID, paneID: target.activePaneID)
        session.update(tab.id) { t in
            t.kind = .tmuxMirror
            t.title = target.displayName
            t.paneSources[paneID] = .tmux(ref)
        }
        let connection: TmuxServerConnection
        do {
            connection = try store.connection(for: target.binding)
        } catch {
            log.error("cannot mirror \(target.displayName, privacy: .private): \(String(describing: error), privacy: .public)")
            // No tmux spoke here, so there is no reason of tmux's to show;
            // the log keeps the system's.
            TabActions.closeTab(session, registry: registry, tabID: tab.id, confirm: false, isReopenable: false)
            store.onNotice?(TmuxConnectionStore.openFailureNotice(name: target.displayName, reason: nil))
            return false
        }
        let mirror = TmuxWindowMirror(
            tabID: tab.id,
            windowID: target.windowID,
            sessionName: target.binding.sessionName,
            windowName: target.windowName,
            connection: connection,
            session: session,
            registry: registry,
            secureInput: secureInput,
            channelForPane: { [weak store] in store?.channel(paneID: $0) },
            surfaceReports: { [weak store] in store?.surfaceReports ?? TmuxSurfaceReports() }
        )
        // tmux refused a verb (`%error`): the picture stays as it was and
        // the user reads which operation failed (design §12).
        mirror.onCommandFailed = { [weak toastCenter] message in
            toastCenter?.show(ToastItem(message: message, undo: nil))
        }
        store.register(mirror)
        mirror.start()
        return true
    }

    /// What the user chose about clients another app has attached.
    enum OtherClientsChoice: Equatable {
        case detachAndOpen
        case openWithoutDetaching
        case cancel
    }

    // swiftlint:disable function_parameter_count
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
        registry: any SurfaceViewProviding,
        secureInput: SecureInputManager?,
        toastCenter: ToastCenter?,
        limpidTTYs: Set<String>? = nil,
        confirm: @escaping @MainActor (TmuxMirrorTarget, [TmuxAttachedClient]) -> OtherClientsChoice = askAboutOtherClients
    ) -> Task<Void, Never>? {
        let finish: () -> Void = {
            open(target, session: session, store: store, registry: registry, secureInput: secureInput, toastCenter: toastCenter)
        }
        // `open` makes the same check; answering here keeps a window that is
        // already on screen from waiting on a child process.
        guard store.liveMirror(showing: target.windowID, of: target.binding) == nil,
              let tmuxPath = store.tmuxExecutable
        else {
            finish()
            return nil
        }
        let ttys = limpidTTYs ?? paneTTYs(session: session, registry: registry)
        let ownPIDs = store.ownControlPIDs
        let binding = target.binding
        return Task {
            let found = await findClientsDetachingLimpidPanes(
                tmuxPath: tmuxPath,
                binding: binding,
                ownControlPIDs: ownPIDs,
                limpidTTYs: ttys
            )
            if !found.otherApps.isEmpty {
                switch confirm(target, found.otherApps) {
                case .cancel:
                    return
                case .openWithoutDetaching:
                    break
                case .detachAndOpen:
                    await detach(found.otherApps, tmuxPath: tmuxPath, socketPath: binding.socketPath)
                }
            }
            finish()
        }
    }

    // swiftlint:enable function_parameter_count

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

    // swiftlint:disable function_parameter_count
    /// Move a pane into a tab of its own. For a mirror tab this is
    /// `break-pane`: tmux gives the pane a new window, and a mirror tab is
    /// opened on that window once tmux reports its id. Anything else goes
    /// the ordinary way.
    static func movePaneToNewTab(
        _ session: WindowSession,
        paneID: UUID,
        store: TmuxConnectionStore?,
        registry: any SurfaceViewProviding,
        secureInput: SecureInputManager?,
        toastCenter: ToastCenter?
    ) {
        guard let sourceTab = session.tab(containing: paneID) else { return }
        guard sourceTab.kind == .tmuxMirror else {
            TabActions.movePaneToNewTab(session, paneID: paneID)
            return
        }
        guard sourceTab.splitTree.allLeafIDs().count > 1,
              let store,
              let mirror = PaneActions.liveMirror(for: sourceTab, in: store, toastCenter: toastCenter),
              case let .tmux(ref) = sourceTab.ioSource(for: paneID)
        else { return }
        mirror.breakPane(paneID: paneID) { windowID in
            guard let windowID else { return }
            mirror.release(paneID: paneID)
            let target = TmuxMirrorTarget(
                binding: ref.binding,
                windowID: windowID,
                windowName: sourceTab.title,
                activePaneID: ref.paneID,
                serverVersion: mirror.connection.version
            )
            open(target, session: session, store: store, registry: registry, secureInput: secureInput, toastCenter: toastCenter)
        }
    }

    // swiftlint:enable function_parameter_count

    /// Merge a pane into another tab. Two mirror tabs on the same tmux
    /// session use `join-pane`; a tmux pane cannot leave tmux, and a mirror
    /// tab stays pure (design §1), so every other pairing that involves a
    /// mirror is refused with a word to the user. Two mirror tabs of which
    /// either is disconnected cannot ask tmux, and say so.
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
        let sourceIsMirror = sourceTab.kind == .tmuxMirror
        if !sourceIsMirror, targetTab.capabilities.canAcceptForeignPane {
            TabActions.mergePaneIntoTab(session, paneID: paneID, into: targetTabID)
            return
        }
        if sourceIsMirror, targetTab.kind == .tmuxMirror {
            guard let source = store?.liveMirror(for: sourceTab.id), let target = store?.liveMirror(for: targetTabID) else {
                toastCenter?.show(ToastItem(message: String(localized: "Not connected to tmux"), undo: nil))
                return
            }
            if source.connection.target == target.connection.target {
                source.joinPane(paneID: paneID, into: target.windowID)
                return
            }
        }
        toastCenter?.show(ToastItem(message: String(localized: "A tmux pane can only move between windows of its own session"), undo: nil))
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
        guard let text = pasteboard.string(forType: .string), !text.isEmpty,
              let tab = session.tab(containing: paneID)
        else { return }
        guard text.utf8.count <= TmuxPasteBuffer.byteLimit else {
            toastCenter?.show(ToastItem(message: String(localized: "The clipboard is too large to paste into a tmux pane"), undo: nil))
            return
        }
        guard let mirror = PaneActions.liveMirror(for: tab, in: store, toastCenter: toastCenter) else { return }
        guard TmuxPasteBuffer.needsConfirmation(text) else {
            mirror.paste(text, paneID: paneID)
            return
        }
        confirmation?.enqueueMirrorPaste(contents: text, view: view) { [weak mirror] in
            mirror?.paste(text, paneID: paneID)
        }
    }
}
