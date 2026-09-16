// TmuxMirrorActions.swift
// Limpid — opens a tab that mirrors one tmux window.

import Foundation
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
    /// server that refuses us leaves a mirror tab with a dormant pane,
    /// which is the state a lost connection produces too.
    @discardableResult
    static func open(
        _ target: TmuxMirrorTarget,
        session: WindowSession,
        store: TmuxConnectionStore,
        registry: any SurfaceViewProviding,
        secureInput: SecureInputManager?,
        toastCenter: ToastCenter? = nil
    ) -> Bool {
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
            return false
        }
        let mirror = TmuxWindowMirror(
            tabID: tab.id,
            windowID: target.windowID,
            connection: connection,
            session: session,
            registry: registry,
            secureInput: secureInput
        )
        // tmux refused a verb (`%error`): the picture stays as it was and
        // the user reads why (design §12).
        mirror.onCommandFailed = { [weak toastCenter] message in
            toastCenter?.show(ToastItem(message: message, undo: nil))
        }
        store.register(mirror)
        mirror.start()
        return true
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
                activePaneID: ref.paneID
            )
            open(target, session: session, store: store, registry: registry, secureInput: secureInput, toastCenter: toastCenter)
        }
    }

    // swiftlint:enable function_parameter_count

    /// Merge a pane into another tab. Two mirror tabs on the same tmux
    /// session use `join-pane`; a tmux pane cannot leave tmux, and a mirror
    /// tab stays pure (design §1), so every other pairing that involves a
    /// mirror is refused with a word to the user.
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
        if sourceIsMirror, let source = store?.mirror(for: sourceTab.id), let target = store?.mirror(for: targetTabID),
           source.connection.target == target.connection.target
        {
            source.joinPane(paneID: paneID, into: target.windowID)
            return
        }
        toastCenter?.show(ToastItem(message: String(localized: "A tmux pane can only move between windows of its own session"), undo: nil))
    }
}
