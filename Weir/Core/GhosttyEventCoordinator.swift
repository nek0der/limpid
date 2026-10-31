// GhosttyEventCoordinator.swift
// Weir — applies libghostty action events to the @Observable
// WorkspaceSession. Receives typed `GhosttyEvent` from
// `GhosttyActionRouter` via the static `sink` closure installed by
// AppState at boot.

import AppKit
import Foundation
import GhosttyKit
import OSLog
import WeirDomain

private let log = Logger.weir("ghostty.events")

@MainActor
final class GhosttyEventCoordinator {
    /// Debounce window applied to libghostty SET_TITLE updates so a
    /// shell that prints "exit" right before terminating doesn't flash
    /// it onto the tab before close_surface_cb fires.
    private static let setTitleDebounce: TimeInterval = 0.08

    private weak var ghosttyApp: GhosttyApp?
    private weak var session: WorkspaceSession?
    private let registry: any SurfaceViewProviding
    private let notificationManager: WeirNotificationManager
    private let bellFeaturesProvider: () -> BellFeatures
    private let secureInputManager: SecureInputManager
    private weak var attention: AttentionState?
    /// Offered a surface's close and exit events before the registry
    /// lookup that would otherwise drop them, for a surface that lives
    /// outside the pane registry (the quick terminal's). Returns true when
    /// it took the event. A closure rather than the owner itself so Core
    /// does not depend on the UI type that owns that surface.
    private let claimsSurfaceExit: @MainActor (SurfaceView) -> Bool
    /// The window a request aimed at the app rather than a pane acts in
    /// (a GOTO_TAB with no surface): the one commands act on. A closure
    /// because the app layer, which owns the windows, decides it.
    private let commandWindow: @MainActor () -> WindowID
    private let linkOpener: TerminalLinkOpener
    /// Told of every finished foreground command (COMMAND_FINISHED), before
    /// the notification's own filters: a resume typed into a pane is over
    /// once its command returns to the shell (`StopLedgerStore`). A closure
    /// because the app layer owns the ledger.
    private let onCommandFinished: @MainActor (_ paneID: UUID, _ exitCode: Int, _ durationNs: UInt64) -> Void
    /// Told of every title a pane's terminal reports, before any is left
    /// off the tab's name: the shell names a command as it starts it, the
    /// one mark a command's start leaves, Weir's own typed commands
    /// included (`PaneAgentInFrontFollower`).
    private let onTitleChanged: @MainActor (_ paneID: UUID) -> Void
    /// What each pane's program last reported over OSC 7501, which also
    /// decides the titles an agent's tab leaves off. Optional so a
    /// coordinator built for a test needs none.
    private let programStatus: PaneProgramStatusStore?

    /// Pending SET_TITLE applies, keyed by pane id. We debounce title
    /// updates by a tiny delay so a shell that prints the command name
    /// (e.g. "exit") into the title right before terminating doesn't
    /// flash on screen between the title change and close_surface_cb.
    private var pendingTitleApplies: [UUID: Task<Void, Never>] = [:]

    /// Per-pane bell-flash drain task. The shell can ring BEL twice
    /// inside the flash window (`tail -f` style bursts, repeated `\a`
    /// from autocomplete misses), and an unmanaged Task lets the
    /// first run's late `setBell(false)` darken the second flash
    /// prematurely. Keying by paneID and canceling the previous
    /// before scheduling lets the latest fire own the cleanup.
    private var pendingBellFlashes: [UUID: Task<Void, Never>] = [:]

    init(
        ghosttyApp: GhosttyApp?,
        session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        notificationManager: WeirNotificationManager,
        bellFeaturesProvider: @escaping () -> BellFeatures,
        secureInputManager: SecureInputManager,
        attention: AttentionState? = nil,
        claimsSurfaceExit: @escaping @MainActor (SurfaceView) -> Bool = { _ in false },
        commandWindow: @escaping @MainActor () -> WindowID,
        linkOpener: TerminalLinkOpener,
        onTitleChanged: @escaping @MainActor (_ paneID: UUID) -> Void = { _ in },
        onCommandFinished: @escaping @MainActor (_ paneID: UUID, _ exitCode: Int, _ durationNs: UInt64) -> Void = { _, _, _ in },
        programStatus: PaneProgramStatusStore? = nil
    ) {
        self.ghosttyApp = ghosttyApp
        self.session = session
        self.registry = registry
        self.notificationManager = notificationManager
        self.bellFeaturesProvider = bellFeaturesProvider
        self.secureInputManager = secureInputManager
        self.attention = attention
        self.claimsSurfaceExit = claimsSurfaceExit
        self.commandWindow = commandWindow
        self.linkOpener = linkOpener
        self.onTitleChanged = onTitleChanged
        self.onCommandFinished = onCommandFinished
        self.programStatus = programStatus
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
        case let .gotoTab(view, rawIndex):
            handleGotoTab(view: view, rawIndex: rawIndex)
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
        case let .scrollbar(view, state):
            view.updateScrollbarState(state)
        case let .cellSize(view):
            handleCellSize(view: view)
        case let .closeSurface(view, _):
            handleCloseSurface(view: view)
        case let .mouseOverLink(view, url):
            handleMouseOverLink(view: view, url: url)
        case let .openUrl(view, url, source):
            if let url {
                linkOpener.open(url, source: source, baseDirectories: linkBaseDirectories(for: view), window: view?.window)
            } else {
                linkOpener.reject(.malformed)
            }
        case let .mouseShape(view, shape):
            handleMouseShape(view: view, shape: shape)
        case let .secureInput(view, mode):
            secureInputManager.set(mode, for: view)
        case let .programStatus(view, report):
            guard let paneID = registry.id(for: view) else { return }
            programStatus?.receive(report, in: paneID)
        case .softReload(.app):
            ghosttyApp?.softReload(surface: nil)
        case let .softReload(.surface(view)):
            guard let surface = view.surface else { return }
            ghosttyApp?.softReload(surface: surface)
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
        // An agent that reports its status over OSC 7501 also writes
        // titles of its own, which the projection's name for its tab would
        // race (`PaneProgramStatusStore.silencesTitle`). Left off before
        // anything reads it, as when the agent wrote none.
        if programStatus?.silencesTitle(title, from: paneID) == true {
            log.debug("SET_TITLE ignored: the agent in the pane reports its status")
            return
        }
        onTitleChanged(paneID)

        // A command Weir typed (a resume, a new conversation) is an
        // implementation detail, not a name the user chose for this tab.
        // Shell integration reports that command through OSC 2 immediately
        // before execution, and a shell with more hooks reports it again;
        // every report of it is left off, and every other title passes.
        if view.isInjectedCommandTitle(title) {
            log.debug("SET_TITLE ignored: a command Weir typed")
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
            try? await Task.sleep(for: .seconds(Self.setTitleDebounce))
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
        log.notice("SET_TITLE applied to tab \(tabID, privacy: .public): \(title, privacy: .private)")
    }

    /// GOTO_TAB switches the active tab among the tabs of the sidebar row
    /// (container) that holds the surface the key went to, in the window
    /// showing that tab (`GotoTabRoute`); one with no surface, in the
    /// window commands act on.
    private func handleGotoTab(view: SurfaceView?, rawIndex raw: Int32) {
        guard let session else { return }
        let paneID = view.flatMap { registry.id(for: $0) }
        guard let route = GotoTabRoute.resolve(
            rawIndex: raw,
            fromPane: paneID,
            commandWindow: commandWindow(),
            in: session
        ) else { return }
        session.setActiveTab(route.tabID, in: route.window, intent: .person)
    }

    /// COMMAND_FINISHED — the shell integration's preexec/precmd hook
    /// reported a finished foreground command.
    private func handleCommandFinished(view: SurfaceView, exitCode exit: Int, durationNs: UInt64) {
        // A shell without title integration never emits the matching OSC 2.
        // Command completion is the other exact lifetime boundary after which
        // an initial-command title must no longer be suppressed.
        view.clearInjectedCommandTitleGuard()
        guard let paneID = registry.id(for: view) else { return }
        // The program that reported a status is gone once its command is
        // back at the shell, cleared or not: one killed or crashed sends no
        // clear, and its status would keep the shell's titles off the tab.
        programStatus?.forget(paneID)
        onCommandFinished(paneID, exit, durationNs)

        let config = CommandFinishConfig.default
        guard config.mode != .never else { return }

        let durationSeconds = Double(durationNs) / 1_000_000_000.0
        guard durationSeconds >= config.minimumDuration else { return }

        let isFocusedSource = WeirNotificationDelegate.isViewFocused(view)
        if config.mode == .unfocused, isFocusedSource {
            return
        }

        let owningTab = session?.tab(containing: paneID)
        let title = owningTab?.shownTitle ?? "Weir"
        let locale = notificationManager.appLocale()
        let exitFragment: String = {
            if exit < 0 {
                return ""
            }
            return LocalizedStringResource(
                " (exit \(exit))",
                comment: "Command-finished notification — exit code fragment"
            ).resolved(in: locale)
        }()
        let durationLabel = DurationText.command(durationSeconds, locale: locale)
        let body = LocalizedStringResource(
            "Finished in \(durationLabel)\(exitFragment)",
            comment: "Command-finished notification body — duration + optional exit fragment"
        ).resolved(in: locale)

        if config.channels.contains(.notify) {
            notificationManager.send(
                title: title,
                body: body,
                paneID: paneID,
                tabID: owningTab?.id,
                containerID: owningTab?.container,
                requireFocus: config.mode == .unfocused,
                kind: .commandFinished,
                tabTitleSnapshot: owningTab?.shownTitle,
                containerLabel: owningTab.map { session?.containerLabel(for: $0.container, locale: locale) } ?? nil,
                exitCode: exit >= 0 ? exit : nil,
                durationSeconds: durationSeconds
            )
            if !isFocusedSource {
                session?.markUnread(paneID: paneID)
            }
        }
        if config.channels.contains(.bell) {
            NSSound.beep()
        }
    }

    /// RING_BELL — `printf '\a'` from the shell, or any escape that
    /// emits BEL. Fans out across the enabled `BellFeatures` channels.
    private func handleRingBell(view: SurfaceView) {
        guard let paneID = registry.id(for: view) else {
            log.error("RING_BELL: no paneID for view")
            return
        }
        let features = bellFeaturesProvider()
        // Shells ring BEL for "tab completion: no match" — extremely
        // frequent when the user is actively typing. Treat the source
        // pane being focused as "the user is right here, no need to
        // bounce the Dock". The pane flash still fires because it is the
        // visible feedback the Visual setting promises in that state.
        let isFocusedSource = WeirNotificationDelegate.isViewFocused(view)
        let hasSystem = features.contains(.system)
        let hasAttention = features.contains(.attention)
        let hasPaneFlash = features.contains(.paneFlash)
        log.notice(
            """
            RING_BELL focusedSource=\(isFocusedSource, privacy: .public) \
            features=(system=\(hasSystem, privacy: .public) \
            attention=\(hasAttention, privacy: .public) \
            paneFlash=\(hasPaneFlash, privacy: .public))
            """
        )

        if features.contains(.system) {
            NSSound.beep()
        }
        if features.contains(.attention), !isFocusedSource {
            NSApp.requestUserAttention(.informationalRequest)
        }
        // A bell rung where the person is not looking stays as the pane's
        // unread mark (the tab's dot, and the Dock's dot when nothing
        // needs attention) until they look, which clears it. The flash and
        // the beep are gone by then.
        if let session,
           features.leavesUnreadMark(
               isSourceFocused: isFocusedSource,
               isAlreadyUnread: session.paneState(paneID).hasUnread
           )
        {
            session.markUnread(paneID: paneID)
        }
        if features.contains(.paneFlash) {
            session?.setBell(paneID: paneID, ringing: true)
            // Cancel the previous drain — without this, a second BEL
            // within the flash window would leave the first task to
            // race the second to `setBell(false)` and prematurely
            // darken the visible flash.
            pendingBellFlashes[paneID]?.cancel()
            pendingBellFlashes[paneID] = Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(nanoseconds: BellFeatures.paneFlashNanoseconds)
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
        // the agent projection is already publishing an enriched wait
        // notification ("… is waiting for approval") for this pane (Weir's
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
        if let badge = owningTab?.agentBadges[.claude]?[paneID],
           badge.state == .needsInput,
           Date().timeIntervalSince(badge.updatedAt) < 60
        {
            log.notice("DESKTOP_NOTIFICATION suppressed (needsInput badge active)")
            return
        }

        let title = explicitTitle.isEmpty
            ? (owningTab?.shownTitle ?? "Weir")
            : explicitTitle

        notificationManager.send(
            title: title,
            body: body,
            paneID: paneID,
            tabID: owningTab?.id,
            containerID: owningTab?.container,
            requireFocus: true,
            kind: .desktop,
            tabTitleSnapshot: owningTab?.shownTitle,
            containerLabel: owningTab.map { session.containerLabel(for: $0.container, locale: notificationManager.appLocale()) }
        )

        let isFocusedSource = WeirNotificationDelegate.isViewFocused(view)
        log.notice("DESKTOP_NOTIFICATION focusedSource=\(isFocusedSource, privacy: .public)")
        if !isFocusedSource {
            session.markUnread(paneID: paneID)
        }
    }

    /// SHOW_CHILD_EXITED — a surface's child process terminated (a pane's, or the quick terminal's).
    private func handleChildExited(view: SurfaceView, exitCode: UInt32) {
        // A shell that dies right after launch gets no close request of its
        // own, only this event. The quick terminal has nowhere to show the
        // exit, so it hides and starts fresh on the next summon.
        if claimsSurfaceExit(view) {
            return
        }
        guard let paneID = registry.id(for: view) else { return }
        session?.setChildExited(paneID: paneID, code: exitCode)
    }

    /// CLOSE_SURFACE — fired by `GhosttyApp.closeSurfaceCallback` for a
    /// pane's surface or the quick terminal's. For a pane, remove the
    /// corresponding leaf from the owning tab's SplitTree; if that was the
    /// last leaf, close the tab too.
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
        // The quick terminal's surface is not in the registry, so it has to
        // be claimed before the lookup below drops the event.
        if claimsSurfaceExit(view) {
            return
        }
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
        programStatus?.forget(paneID)
        session.paneSearchStates.removeValue(forKey: paneID)
        session.paneTransients.removeValue(forKey: paneID)
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

    /// Only surfaces of this window bump it; another window's grid does not
    /// concern the views observing this session.
    private func handleCellSize(view: SurfaceView) {
        guard let session, registry.id(for: view) != nil else { return }
        session.cellSizeGeneration &+= 1
        // The grid moved with the font; the next report compares against it.
        view.reportGridSizeIfChanged()
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
        session.setWorkingDirectory(paneID: paneID, path: pwd)
    }

    // MARK: - Link / cursor handlers

    /// A surface outside the pane registry (the quick terminal's) has no
    /// session entry, so only libghostty's own resolution applies there.
    private func linkBaseDirectories(for view: SurfaceView?) -> [URL] {
        guard let view, let session, let paneID = registry.id(for: view) else {
            log.debug("link bases: hasView=\(view != nil, privacy: .public), no pane")
            return []
        }
        let bases = session.linkBaseDirectories(paneID: paneID)
        // Whether each base exists is what tells a wrong base from a
        // missing file when a click is refused; the paths stay private.
        let existing = bases.map { FileManager.default.fileExists(atPath: $0.path) }
        log.debug("link bases: count=\(bases.count, privacy: .public) exist=\(existing, privacy: .public)")
        return bases
    }

    private func handleMouseOverLink(view: SurfaceView, url: String?) {
        view.hoverUrl = url
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

/// Where a libghostty GOTO_TAB goes: which tab, in which window.
///
/// Resolved from the surface the key went to (leaf, then its tab, then the
/// window showing that tab), never from the menu's target
/// (`WindowRegistry.commandTarget`): a key libghostty handles does not pass
/// through `Commands`, and the window it went to is the surface's, not
/// whichever window AppKit has key.
@MainActor
enum GotoTabRoute {
    struct Route: Equatable {
        let tabID: UUID
        /// The window whose selection moves.
        let window: WindowID
    }

    /// The tab `raw` names among the tabs beside `paneID`'s tab, in the
    /// window that shows `paneID`'s tab: the primary when it does, else
    /// the first other window by ID, so two windows on one tab always
    /// resolve the same way. A pane no window shows moves nothing: the key
    /// reached a terminal no one sees, and no window chose it. Without a
    /// pane (a request aimed at the app) the tab moved from is the one
    /// `commandWindow`, where commands act, shows; nothing moves when the
    /// session does not know that window.
    static func resolve(
        rawIndex raw: Int32,
        fromPane paneID: UUID?,
        commandWindow: WindowID,
        in session: WorkspaceSession
    ) -> Route? {
        let window: WindowID
        let current: Tab?
        if let paneID {
            guard let shownIn = session.window(showingPane: paneID) else { return nil }
            window = shownIn
            current = session.tab(containing: paneID)
        } else {
            guard session.selection(commandWindow) != nil else { return nil }
            window = commandWindow
            current = session.activeTab(in: commandWindow)
        }
        let visible = tabs(beside: current, in: session)
        guard !visible.isEmpty else { return nil }

        let target: Tab?
        switch raw {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue:
            target = neighbor(of: visible, forward: false, current: current?.id)
        case GHOSTTY_GOTO_TAB_NEXT.rawValue:
            target = neighbor(of: visible, forward: true, current: current?.id)
        case GHOSTTY_GOTO_TAB_LAST.rawValue:
            target = visible.last
        default:
            let index = Int(raw) - 1
            guard index >= 0, index < visible.count else { return nil }
            target = visible[index]
        }
        return target.map { Route(tabID: $0.id, window: window) }
    }

    /// The tabs of `current`'s sidebar row (its container), or every tab
    /// without one.
    private static func tabs(beside current: Tab?, in session: WorkspaceSession) -> [Tab] {
        guard let container = current?.container else { return session.tabs }
        return session.tabs(in: container)
    }

    private static func neighbor(of tabs: [Tab], forward: Bool, current: UUID?) -> Tab? {
        let i = current.flatMap { id in tabs.firstIndex(where: { $0.id == id }) } ?? 0
        let n = tabs.count
        let next = forward ? (i + 1) % n : (i - 1 + n) % n
        return tabs[next]
    }
}
