// TmuxMirrorActions+Window.swift
// Limpid — the window actions a mirror tab's chip offers: a new tmux window, the clients attached elsewhere, and quitting the window.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.mirror")

extension TmuxMirrorActions {
    /// Open a new window in the session tab `tabID` shows, and a mirror tab
    /// for it beside this one (design D1).
    ///
    /// The same shape as `movePaneToNewTab`: tmux is asked to make the
    /// window, and only the window it reports back is opened, so a refusal
    /// leaves no empty tab behind. Offered while the tab is connected, so a
    /// mirror that is not live here means the state changed between the
    /// menu opening and the choice, and nothing happens.
    static func newWindow(tabID: UUID, session: WindowSession, store: TmuxConnectionStore) {
        guard let tab = session.tab(tabID),
              let ref = mirrorRef(of: tab),
              let mirror = store.liveMirror(for: tabID)
        else { return }
        mirror.newWindow { window in
            guard let window else { return }
            let target = TmuxMirrorTarget(
                binding: ref.binding,
                windowID: window.windowID,
                windowName: window.windowName,
                activePaneID: window.paneID,
                serverVersion: mirror.connection.version
            )
            // No question about other clients: the window was made a moment
            // ago and nothing else can be showing it yet.
            open(target, session: session, store: store, after: tabID)
        }
    }

    /// Deal with the clients attached to this tab's session from somewhere
    /// else, on the dialog a tab being opened uses (design D7). tmux fits a
    /// window to every client showing it, so a client of another app can
    /// hold this tab's picture small long after the tab was opened, and
    /// this is how the user gets it back.
    ///
    /// Nothing is said when no other client is attached: the user asked
    /// about the clients and the answer is that there are none, which the
    /// dialog would state as a question.
    @discardableResult
    static func otherClientsAsked(
        tabID: UUID,
        session: WindowSession,
        store: TmuxConnectionStore,
        limpidTTYs: Set<String>? = nil,
        confirm: @escaping @MainActor (TmuxMirrorTarget, [TmuxAttachedClient]) -> OtherClientsChoice = askAboutOtherClients
    ) -> Task<Void, Never>? {
        guard let tab = session.tab(tabID),
              let ref = mirrorRef(of: tab),
              let tmuxPath = store.tmuxExecutable
        else { return nil }
        let target = TmuxMirrorTarget(
            binding: ref.binding,
            windowID: ref.windowID,
            windowName: windowName(of: tab, binding: ref.binding, store: store),
            activePaneID: ref.paneID,
            serverVersion: store.mirror(for: tabID)?.connection.version
        )
        let gate = otherClientsGate(
            tmuxPath: tmuxPath,
            session: session,
            store: store,
            limpidTTYs: limpidTTYs,
            confirm: confirm
        )
        // The gate's answer decides whether an attach goes ahead; this tab
        // is already attached, so there is nothing left to admit.
        return Task { _ = await gate(target) }
    }

    /// What the user is asked before `kill-window` (design D4). The one
    /// action Limpid offers that destroys work in tmux, so it names the
    /// window it would end and what is running in it rather than asking in
    /// the abstract.
    ///
    /// An agent's window is named after its agent, as every other notice
    /// about it is (D6): its session name is one Limpid made up. A user's
    /// window is named `session:window` and its programs are not named one
    /// by one — nothing here knows what runs in each pane — so the message
    /// says what ends and how to keep it instead.
    struct QuitWindowPrompt: Equatable {
        let title: String
        let message: String
        let confirmLabel: String

        init(name: String, isAgent: Bool) {
            title = String(localized: "Quit the tmux window “\(name)”?")
            message = if isAgent {
                String(localized: """
                \(name) is running in this window. Quitting it ends that run, in tmux as well as here, \
                and closes this tab. Closing the tab instead leaves the agent running in the background.
                """)
            } else {
                String(localized: """
                Everything running in this window ends, for every client showing it, and this tab closes. \
                Closing the tab instead leaves the window running in tmux.
                """)
            }
            confirmLabel = String(localized: "Quit Window")
        }
    }

    /// Ask, and on a yes end the tmux window tab `tabID` shows. What becomes
    /// of the tab is left to the `%window-close` tmux answers with, the same
    /// route as a window killed from anywhere else, so the tab closes with
    /// the notice it would have had either way.
    static func quitWindowAsked(
        tabID: UUID,
        session: WindowSession,
        store: TmuxConnectionStore,
        confirm: @MainActor (QuitWindowPrompt) -> Bool = askAboutQuittingWindow
    ) {
        guard let tab = session.tab(tabID),
              let ref = mirrorRef(of: tab),
              let mirror = store.liveMirror(for: tabID)
        else { return }
        let prompt = QuitWindowPrompt(
            name: TmuxConnectionStore.noticeName(
                of: tab,
                tmuxName: TmuxMirrorTarget.displayName(
                    sessionName: ref.binding.sessionName,
                    windowName: windowName(of: tab, binding: ref.binding, store: store)
                )
            ),
            isAgent: tab.mirrorOrigin == .agent
        )
        guard confirm(prompt) else { return }
        log.notice("kill-window for tab \(tabID, privacy: .public)")
        mirror.killWindow()
    }

    static func askAboutQuittingWindow(_ prompt: QuitWindowPrompt) -> Bool {
        LimpidConfirm.runDestructive(
            title: prompt.title,
            message: prompt.message,
            confirmLabel: prompt.confirmLabel
        )
    }
}
