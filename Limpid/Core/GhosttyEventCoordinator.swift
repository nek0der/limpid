// GhosttyEventCoordinator.swift
// Limpid — applies libghostty action events to the @Observable
// WindowSession. Receives typed `GhosttyEvent` from
// `GhosttyActionRouter` via the static `sink` closure installed by
// AppState at boot.

import AppKit
import Foundation
import GhosttyKit
import OSLog

private let log = Logger.limpid("ghostty.events")

@MainActor
final class GhosttyEventCoordinator {
    private weak var session: WindowSession?
    private let registry: any SurfaceViewProviding
    private let notificationManager: LimpidNotificationManager
    private weak var attention: AttentionState?

    /// Pending SET_TITLE applies, keyed by pane id. We debounce title
    /// updates by a tiny delay so a shell that prints the command name
    /// (e.g. "exit") into the title right before terminating doesn't
    /// flash on screen between the title change and close_surface_cb.
    private var pendingTitleApplies: [UUID: Task<Void, Never>] = [:]

    /// Per-pane bell-flash drain task. The shell can ring BEL twice
    /// inside the flash window (`tail -f` style bursts, repeated `\a`
    /// from autocomplete misses), and an unmanaged Task lets the
    /// first run's late `setBell(false)` darken the second flash
    /// prematurely. Keying by paneID and cancelling the previous
    /// before scheduling lets the latest fire own the cleanup.
    private var pendingBellFlashes: [UUID: Task<Void, Never>] = [:]

    init(
        session: WindowSession,
        registry: any SurfaceViewProviding,
        notificationManager: LimpidNotificationManager,
        attention: AttentionState? = nil
    ) {
        self.session = session
        self.registry = registry
        self.notificationManager = notificationManager
        self.attention = attention
    }

    // Single entry point invoked by `GhosttyActionRouter.sink`. Switch
    // on the event tag and apply the resulting mutation to the session.
    // swiftlint:disable:next cyclomatic_complexity
    func dispatch(_ event: GhosttyEvent) {
        switch event {
        case let .setTitle(view, title):
            handleSetTitle(view: view, title: title)
        case let .setPwd(view, pwd):
            handleSetPwd(view: view, pwd: pwd)
        case let .gotoTab(rawIndex):
            handleGotoTab(rawIndex: rawIndex)
        case let .childExited(view, exitCode, _):
            handleChildExited(view: view, exitCode: exitCode)
        case let .desktopNotification(view, title, body):
            handleDesktopNotification(view: view, title: title, body: body)
        case let .ringBell(view):
            handleRingBell(view: view)
        case let .commandFinished(view, exitCode, durationNs):
            handleCommandFinished(view: view, exitCode: exitCode, durationNs: durationNs)
        case let .endSearch(view):
            handleEndSearch(view: view)
        case let .searchTotal(view, total):
            handleSearchTotal(view: view, total: total)
        case let .searchSelected(view, selected):
            handleSearchSelected(view: view, selected: selected)
        case let .closeSurface(view, _):
            handleCloseSurface(view: view)
        case let .mouseOverLink(view, url):
            handleMouseOverLink(view: view, url: url)
        case let .openUrl(url):
            handleOpenUrl(url: url)
        case let .mouseShape(view, shape):
            handleMouseShape(view: view, shape: shape)
        }
    }

    // MARK: - Search handlers

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

        guard let owningTab = session.tab(containing: paneID) else {
            log.debug("SET_TITLE no owning tab for paneID")
            return
        }

        guard shouldPropagateTitle(from: paneID, in: owningTab) else { return }

        pendingTitleApplies[paneID]?.cancel()
        let tabID = owningTab.id
        pendingTitleApplies[paneID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(LimpidLayout.setTitleDebounce))
            guard !Task.isCancelled else { return }
            self?.applySetTitle(tabID: tabID, paneID: paneID, title: title)
        }
    }

    /// Decide whether `paneID`'s OSC 2 should be propagated up to
    /// `tab.title`. Two regimes:
    ///   1. **Agent in the tab** — only the pane whose Claude / Codex
    ///      session started most recently is allowed, regardless of
    ///      focus. The tab label is "owned" by the latest conversation
    ///      so a background claude pane writing a fresh `terminalSequence`
    ///      still updates the tab; conversely a foregrounded pane that
    ///      isn't the latest owner is silenced so an older session can't
    ///      clobber the label.
    ///   2. **No agent at all** — fall back to the legacy "focused
    ///      pane only" rule so a plain shell tab still behaves the way
    ///      it always has (background pane prompts don't flicker the
    ///      tab name).
    private func shouldPropagateTitle(from paneID: UUID, in tab: Tab) -> Bool {
        if let owner = tab.latestAgentSessionPaneID {
            if owner != paneID {
                log.debug("SET_TITLE ignored: pane is not the latest agent session owner")
                return false
            }
            return true
        }
        if let focused = tab.splitTree.focusedLeafID, focused != paneID {
            log.debug("SET_TITLE recorded on bg pane only")
            return false
        }
        return true
    }

    private func applySetTitle(tabID: UUID, paneID: UUID, title: String) {
        guard let session,
              let tab = session.tabs.first(where: { $0.id == tabID })
        else {
            pendingTitleApplies.removeValue(forKey: paneID)
            return
        }
        pendingTitleApplies.removeValue(forKey: paneID)
        // Re-check the propagate gate now — between the 80ms debounce
        // schedule and this apply, `latestAgentSessionPaneID` may have
        // shifted (a newer agent session opened in a sibling pane), in
        // which case the still-in-flight write would clobber the new
        // owner's title. The schedule-side gate only catches the case
        // where the same pane re-fires; an OSC 2 from a now-bg pane
        // followed by no OSC 2 from the new owner would otherwise win
        // the race.
        guard shouldPropagateTitle(from: paneID, in: tab) else {
            log.debug("SET_TITLE apply suppressed (owner shifted during debounce)")
            return
        }

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
            return String(
                localized: " (exit \(exit))",
                comment: "Command-finished notification — exit code fragment"
            )
        }()
        let durationLabel = formatDuration(durationSeconds)
        let body = String(
            localized: "Finished in \(durationLabel)\(exitFragment)",
            comment: "Command-finished notification body — duration + optional exit fragment"
        )

        if config.channels.contains(.notify) {
            notificationManager.send(
                title: title,
                body: body,
                paneID: paneID,
                tabID: owningTab?.id,
                containerID: owningTab?.container,
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

    /// Locale-aware short duration formatter used by the
    /// command-finished notification body. The earlier shape relied on
    /// `String(format: "%.1fs", …)` which pinned the C locale's `.`
    /// decimal separator and English unit suffixes — comma-decimal
    /// locales would have read "1,5s" as "15s" and ja users saw "1.5s"
    /// inline with otherwise translated copy.
    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return Duration.seconds(seconds).formatted(
                .units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1))
            )
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return Duration.seconds(m * 60 + s).formatted(
            .units(allowed: [.minutes, .seconds], width: .narrow)
        )
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
            // Cancel the previous drain — without this, a second BEL
            // within the flash window would leave the first task to
            // race the second to `setBell(false)` and prematurely
            // darken the visible flash.
            pendingBellFlashes[paneID]?.cancel()
            pendingBellFlashes[paneID] = Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(nanoseconds: LimpidMotion.bellFlashNanoseconds)
                guard !Task.isCancelled else { return }
                session?.setBell(paneID: paneID, ringing: false)
                self?.pendingBellFlashes.removeValue(forKey: paneID)
            }
        }
    }

    /// DESKTOP_NOTIFICATION — shell printed OSC 9 / OSC 777.
    private func handleDesktopNotification(view: SurfaceView, title explicitTitle: String, body: String) {
        guard let session,
              let paneID = registry.id(for: view)
        else { return }

        let owningTab = session.tab(containing: paneID)

        // Suppress Claude Code's generic OSC 9 / 777 broadcast when
        // our agent-state tracker is already publishing an enriched
        // "Claude needs input" notification for this pane (Limpid's
        // banner carries container + permission / question context;
        // the OSC version is just "Claude is waiting for your input"
        // — duplicate noise).
        //
        // We deliberately do NOT suppress for `.idle` — Claude's
        // own OSC channel is already off via
        // `preferredNotifChannel: notifications_disabled` in
        // `settings.template.json`, so any OSC that reaches this
        // path while the pane is `.idle` is **not from Claude**
        // (a user-run script, `make test`, etc.) and should reach
        // the user. The freshness window (60s) keeps stale badges
        // from gating unrelated notifications indefinitely.
        if let badge = owningTab?.claudeAgentBadges[paneID],
           badge.state == .needsInput,
           Date().timeIntervalSince(badge.updatedAt) < 60
        {
            log.notice("DESKTOP_NOTIFICATION suppressed (needsInput badge active)")
            return
        }

        let title = explicitTitle.isEmpty
            ? (owningTab?.displayTitle ?? "Limpid")
            : explicitTitle

        notificationManager.send(
            title: title,
            body: body,
            paneID: paneID,
            tabID: owningTab?.id,
            containerID: owningTab?.container,
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

    /// CLOSE_SURFACE — fired by `GhosttyApp.closeSurfaceCallback`.
    /// Remove the corresponding leaf from the owning tab's SplitTree;
    /// if that was the last leaf, close the tab too.
    private func handleCloseSurface(view: SurfaceView) {
        // Dismiss any clipboard-confirmation sheet tied to this pane.
        // The pane is about to be freed but the surface is still live
        // *now*, so route the cancellation through the coordinator's
        // deny() path: that call frees libghostty's per-request
        // `ClipboardRequest` allocation. Just nil-ing `pending` would
        // strand the allocation (only `complete_clipboard_request`
        // releases it; `Surface.deinit` does not walk pending request
        // states).
        ClipboardConfirmationCoordinator.shared?.cancelPending(for: view)
        guard let session,
              let paneID = registry.id(for: view)
        else {
            log.debug("CLOSE_SURFACE dropped (no paneID)")
            return
        }
        pendingTitleApplies[paneID]?.cancel()
        pendingTitleApplies.removeValue(forKey: paneID)
        pendingBellFlashes[paneID]?.cancel()
        pendingBellFlashes.removeValue(forKey: paneID)
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
        // `closeTab` already forgets every leaf in the collapsing tab,
        // so only the multi-pane branch needs an explicit sweep here.
        // Without this, `AttentionState.dismissedAt` / `viewedAt` would
        // keep entries for paneIDs that no longer exist, defeating the
        // "don't grow without bound across long sessions" contract on
        // `forget`.
        if oldLeafCount == 1 {
            session.closeTab(owningTab.id)
            log.notice("CLOSE_SURFACE collapsed tab \(owningTab.id, privacy: .public)")
        } else {
            attention?.forget(paneID: paneID)
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

    // MARK: - Link / cursor handlers

    private func handleMouseOverLink(view: SurfaceView, url: String?) {
        view.hoverUrl = url
    }

    private func handleOpenUrl(url: String) {
        guard let nsURL = URL(string: url) else {
            log.warning("OPEN_URL invalid URL: \(url, privacy: .private)")
            return
        }
        NSWorkspace.shared.open(nsURL)
    }

    private func handleMouseShape(view: SurfaceView, shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor = switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: .resizeUpDown
        default: .arrow
        }
        view.currentCursor = cursor
        view.window?.invalidateCursorRects(for: view)
    }
}
