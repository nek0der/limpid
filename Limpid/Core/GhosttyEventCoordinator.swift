// GhosttyEventCoordinator.swift
// Limpid — applies libghostty action events to the @Observable
// WindowSession. Receives typed `GhosttyEvent` from
// `GhosttyActionRouter` via the static `sink` closure installed by
// AppState at boot.

import AppKit
import Foundation
import GhosttyKit
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "ghostty.events")

@MainActor
final class GhosttyEventCoordinator {
    private weak var session: WindowSession?
    private weak var ghosttyApp: GhosttyApp?
    private let registry: any SurfaceViewProviding
    private let notificationManager: LimpidNotificationManager

    /// Pending SET_TITLE applies, keyed by pane id. We debounce title
    /// updates by a tiny delay so a shell that prints the command name
    /// (e.g. "exit") into the title right before terminating doesn't
    /// flash on screen between the title change and close_surface_cb.
    private var pendingTitleApplies: [UUID: Task<Void, Never>] = [:]

    init(
        session: WindowSession,
        registry: any SurfaceViewProviding,
        ghosttyApp: GhosttyApp?,
        notificationManager: LimpidNotificationManager
    ) {
        self.session = session
        self.registry = registry
        self.ghosttyApp = ghosttyApp
        self.notificationManager = notificationManager
    }

    /// Single entry point invoked by `GhosttyActionRouter.sink`. Switch
    /// on the event tag and apply the resulting mutation to the
    /// session.
    func dispatch(_ event: GhosttyEvent) {
        switch event {
        case let .setTitle(view, title):
            handleSetTitle(view: view, title: title)
        case let .setPwd(view, pwd):
            handleSetPwd(view: view, pwd: pwd)
        case let .gotoTab(rawIndex):
            handleGotoTab(rawIndex: rawIndex)
        case let .newSplit(origin, direction, inherited):
            handleNewSplit(origin: origin, direction: direction, inherited: inherited)
        case let .closeTab(origin, mode):
            handleCloseTab(origin: origin, mode: mode)
        case let .childExited(view, exitCode, _):
            handleChildExited(view: view, exitCode: exitCode)
        case let .desktopNotification(view, title, body):
            handleDesktopNotification(view: view, title: title, body: body)
        case let .ringBell(view):
            handleRingBell(view: view)
        case let .commandFinished(view, exitCode, durationNs):
            handleCommandFinished(view: view, exitCode: exitCode, durationNs: durationNs)
        case let .startSearch(view, needle):
            handleStartSearch(view: view, needle: needle)
        case let .endSearch(view):
            handleEndSearch(view: view)
        case let .searchTotal(view, total):
            handleSearchTotal(view: view, total: total)
        case let .searchSelected(view, selected):
            handleSearchSelected(view: view, selected: selected)
        case let .closeSurface(view, _):
            handleCloseSurface(view: view)
        }
    }

    // MARK: - Search handlers

    private func handleStartSearch(view: SurfaceView, needle: String) {
        guard let session, let id = registry.id(for: view) else { return }
        let state = session.paneSearchStates[id] ?? PaneSearchState()
        state.needle = needle
        session.paneSearchStates[id] = state
    }

    private func handleEndSearch(view: SurfaceView) {
        guard let session, let id = registry.id(for: view) else { return }
        session.paneSearchStates[id] = nil
    }

    private func handleSearchTotal(view: SurfaceView, total: Int?) {
        guard let session,
              let id = registry.id(for: view),
              let state = session.paneSearchStates[id]
        else { return }
        state.total = total
    }

    private func handleSearchSelected(view: SurfaceView, selected: Int?) {
        guard let session,
              let id = registry.id(for: view),
              let state = session.paneSearchStates[id]
        else { return }
        state.selected = selected
    }

    // MARK: - Handlers

    /// SET_TITLE only flips `tab.title` for the *focused* pane of the
    /// *active* tab. Background panes and background tabs report titles
    /// too, but propagating those would make the tab label jitter every
    /// time another shell prints a prompt.
    private func handleSetTitle(view: SurfaceView, title: String) {
        guard let session,
              let paneID = registry.id(for: view)
        else {
            log.debug("SET_TITLE dropped (missing session/paneID)")
            return
        }

        // Record on the SurfaceView first so a background pane keeps
        // its own title around for when it regains focus later.
        registry.view(for: paneID)?.paneTitle = title

        guard let owningTab = session.tab(containing: paneID) else {
            log.debug("SET_TITLE no owning tab for paneID")
            return
        }

        // Only the focused pane gets to push its title up to the tab.
        if let focused = owningTab.splitTree.focusedLeafID, focused != paneID {
            log.debug("SET_TITLE recorded on bg pane only")
            return
        }

        pendingTitleApplies[paneID]?.cancel()
        let tabID = owningTab.id
        pendingTitleApplies[paneID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LimpidLayout.setTitleDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.applySetTitle(tabID: tabID, paneID: paneID, title: title)
        }
    }

    private func applySetTitle(tabID: UUID, paneID: UUID, title: String) {
        guard let session,
              session.tabs.contains(where: { $0.id == tabID })
        else { return }
        pendingTitleApplies.removeValue(forKey: paneID)

        session.update(tabID) { tab in
            tab.title = title
        }
        // NB: do NOT propagate the title to the parent worktree's
        // `label`. The shell's OSC 2 title is a pwd-style string
        // ("~/dev/foo/bar") — assigning it to the worktree label
        // turns the sidebar row into the current directory path,
        // which is exactly the bug the user hit. Worktree labels are
        // owned by the user (rename) and by GitSync (basename of the
        // disk path) — not by per-pane shell titles.
        log.notice("SET_TITLE applied to tab \(tabID, privacy: .public): \(title, privacy: .public)")
    }

    /// GOTO_TAB switches the active tab within the same sidebar
    /// section as the currently-active tab.
    private func handleGotoTab(rawIndex raw: Int32) {
        guard let session else { return }

        let visible: [Tab] = if let container = session.activeTab?.container {
            switch container {
            case .loose:
                session.looseTabs
            case let .group(gid):
                session.tabs(in: gid)
            case let .project(pid):
                session.directTabs(in: pid)
            case let .worktree(pid, wid):
                session.tabs(inProject: pid, worktree: wid)
            }
        } else {
            session.tabs
        }
        guard !visible.isEmpty else { return }

        let target: Tab?
        switch raw {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue:
            target = neighbor(of: visible, forward: false, current: session.activeTabID)
        case GHOSTTY_GOTO_TAB_NEXT.rawValue:
            target = neighbor(of: visible, forward: true, current: session.activeTabID)
        case GHOSTTY_GOTO_TAB_LAST.rawValue:
            target = visible.last
        default:
            let index = Int(raw) - 1
            guard index >= 0, index < visible.count else { return }
            target = visible[index]
        }
        if let target { session.setActiveTab(target.id) }
    }

    /// COMMAND_FINISHED — the shell integration's preexec/precmd hook
    /// reported a finished foreground command.
    private func handleCommandFinished(view: SurfaceView, exitCode exit: Int, durationNs: UInt64) {
        guard let paneID = registry.id(for: view) else { return }

        let config = CommandFinishConfig.default
        guard config.mode != .never else { return }

        let durationSeconds = Double(durationNs) / 1_000_000_000.0
        guard durationSeconds >= config.minimumDuration else { return }

        let isFocusedSource = LimpidNotificationDelegate.isKeyAndFocused
            && (view.window?.firstResponder === view)
        if config.mode == .unfocused, isFocusedSource { return }

        let owningTab = session?.tab(containing: paneID)
        let title = owningTab?.displayTitle ?? "Limpid"
        let exitFragment: String = {
            if exit < 0 { return "" }
            if exit == 0 { return " (exit 0)" }
            return " (exit \(exit))"
        }()
        let body = "Finished in \(formatDuration(durationSeconds))\(exitFragment)"

        if config.channels.contains(.notify) {
            notificationManager.send(
                title: title,
                body: body,
                paneID: paneID,
                requireFocus: config.mode == .unfocused,
                kind: .commandFinished,
                tabTitleSnapshot: owningTab?.displayTitle,
                containerLabel: owningTab.map { session?.containerLabel(for: $0.container) } ?? nil,
                exitCode: exit >= 0 ? exit : nil,
                durationSeconds: durationSeconds
            )
            if !isFocusedSource { session?.markUnread(paneID: paneID) }
        }
        if config.channels.contains(.bell) {
            NSSound.beep()
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }

    /// RING_BELL — `printf '\a'` from the shell, or any escape that
    /// emits BEL. Fans out across the enabled `BellFeatures` channels.
    private func handleRingBell(view: SurfaceView) {
        guard let paneID = registry.id(for: view) else {
            log.error("RING_BELL: no paneID for view")
            return
        }
        let features = BellFeatures.default
        // Shells ring BEL for "tab completion: no match" — extremely
        // frequent when the user is actively typing. Treat the source
        // pane being focused as "the user is right here, no need to
        // alert" and suppress every attention-grabbing channel; only
        // the system beep (an audible cue, easy to disable via shell
        // config) remains.
        let isFocusedSource = LimpidNotificationDelegate.isKeyAndFocused
            && (view.window?.firstResponder === view)
        let hasSystem = features.contains(.system)
        let hasAttention = features.contains(.attention)
        let hasBorder = features.contains(.border)
        log.notice(
            """
            RING_BELL focusedSource=\(isFocusedSource, privacy: .public) \
            features=(system=\(hasSystem, privacy: .public) \
            attention=\(hasAttention, privacy: .public) \
            border=\(hasBorder, privacy: .public))
            """
        )

        if features.contains(.system) {
            NSSound.beep()
        }
        if features.contains(.attention), !isFocusedSource {
            NSApp.requestUserAttention(.informationalRequest)
        }
        if features.contains(.border), !isFocusedSource {
            session?.setBell(paneID: paneID, ringing: true)
            Task { @MainActor [weak session] in
                try? await Task.sleep(nanoseconds: LimpidMotion.bellFlashNanoseconds)
                session?.setBell(paneID: paneID, ringing: false)
            }
        }
    }

    /// DESKTOP_NOTIFICATION — shell printed OSC 9 / OSC 777.
    private func handleDesktopNotification(view: SurfaceView, title explicitTitle: String, body: String) {
        guard let session,
              let paneID = registry.id(for: view)
        else { return }

        let owningTab = session.tab(containing: paneID)
        let title = explicitTitle.isEmpty
            ? (owningTab?.displayTitle ?? "Limpid")
            : explicitTitle

        notificationManager.send(
            title: title,
            body: body,
            paneID: paneID,
            requireFocus: true,
            kind: .desktop,
            tabTitleSnapshot: owningTab?.displayTitle,
            containerLabel: owningTab.map { session.containerLabel(for: $0.container) }
        )

        let isFocusedSource = LimpidNotificationDelegate.isKeyAndFocused
            && (view.window?.firstResponder === view)
        log.notice("DESKTOP_NOTIFICATION focusedSource=\(isFocusedSource, privacy: .public)")
        if !isFocusedSource {
            session.markUnread(paneID: paneID)
        }
    }

    /// SHOW_CHILD_EXITED — the pane's child process terminated.
    private func handleChildExited(view: SurfaceView, exitCode: UInt32) {
        guard let paneID = registry.id(for: view) else { return }
        session?.setChildExited(paneID: paneID, code: exitCode)
    }

    /// CLOSE_TAB — libghostty's ⌘W keybind.
    private func handleCloseTab(origin view: SurfaceView, mode: ghostty_action_close_tab_mode_e) {
        guard let session,
              let paneID = registry.id(for: view),
              let owningTab = session.tab(containing: paneID)
        else { return }

        let projectID = owningTab.projectID
        let visible = session.tabs.filter { $0.projectID == projectID }
        guard let originIdx = visible.firstIndex(where: { $0.id == owningTab.id }) else { return }

        let doomed: [Tab]
        switch mode {
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS:
            doomed = [owningTab]
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
            doomed = visible.filter { $0.id != owningTab.id }
        case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
            doomed = Array(visible[(originIdx + 1)...])
        default:
            return
        }

        for tab in doomed {
            let leafIDs = tab.splitTree.allLeafIDs()
            session.closeTab(tab.id)
            for id in leafIDs {
                registry.unregister(id)
            }
        }
        log.notice("CLOSE_TAB mode=\(mode.rawValue, privacy: .public) closed \(doomed.count, privacy: .public) tabs")
    }

    /// NEW_SPLIT — libghostty's ⌘D / ⌘⇧D keybind.
    private func handleNewSplit(
        origin originView: SurfaceView,
        direction dir: SplitDirection,
        inherited: InheritedSurfaceConfig
    ) {
        guard let session,
              let ghosttyApp,
              let originPaneID = registry.id(for: originView),
              let owningTab = session.tab(containing: originPaneID)
        else {
            log.debug("NEW_SPLIT dropped (missing context)")
            return
        }

        let newPaneID = registry.createInheritedSurface(
            ghosttyApp: ghosttyApp,
            from: inherited,
            paneID: UUID()
        )
        session.update(owningTab.id) { tab in
            let result = tab.splitTree.insert(
                at: originPaneID,
                direction: dir,
                newID: newPaneID
            )
            tab.splitTree = result.tree
            tab.splitTree.focusedLeafID = newPaneID
        }
        log.notice("NEW_SPLIT inserted \(newPaneID, privacy: .public) (\(dir == .vertical ? "vertical" : "horizontal", privacy: .public))")
    }

    /// CLOSE_SURFACE — fired by `GhosttyApp.closeSurfaceCallback`.
    /// Remove the corresponding leaf from the owning tab's SplitTree;
    /// if that was the last leaf, close the tab too.
    private func handleCloseSurface(view: SurfaceView) {
        guard let session,
              let paneID = registry.id(for: view)
        else {
            log.debug("CLOSE_SURFACE dropped (no paneID)")
            return
        }
        pendingTitleApplies[paneID]?.cancel()
        pendingTitleApplies.removeValue(forKey: paneID)
        session.paneSearchStates.removeValue(forKey: paneID)
        guard let owningTab = session.tab(containing: paneID) else {
            registry.unregister(paneID)
            return
        }

        let oldLeafCount = owningTab.splitTree.allLeafIDs().count
        let result = owningTab.splitTree.remove(paneID)
        session.update(owningTab.id) { tab in
            tab.splitTree = result.tree
            if let focus = result.focusTarget {
                tab.splitTree.focusedLeafID = focus
            }
        }
        registry.unregister(paneID)

        if oldLeafCount == 1 {
            session.closeTab(owningTab.id)
            log.notice("CLOSE_SURFACE collapsed tab \(owningTab.id, privacy: .public)")
        } else {
            log.notice("CLOSE_SURFACE removed pane in tab \(owningTab.id, privacy: .public)")
        }
    }

    private func neighbor(of tabs: [Tab], forward: Bool, current: UUID?) -> Tab? {
        let i = current.flatMap { id in tabs.firstIndex(where: { $0.id == id }) } ?? 0
        let n = tabs.count
        let next = forward ? (i + 1) % n : (i - 1 + n) % n
        return tabs[next]
    }

    /// PWD propagates to every tab whose tree contains the reporting
    /// surface — typically just one tab at a time.
    private func handleSetPwd(view: SurfaceView, pwd: String) {
        guard let session,
              let paneID = registry.id(for: view)
        else { return }

        if let tab = session.tab(containing: paneID) {
            session.update(tab.id) { t in
                t.pwd = pwd
            }
        }
    }
}
