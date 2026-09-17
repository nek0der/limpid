// ReviewAgents.swift
// Limpid — resolve where review writes, and write there.

import Foundation
import OSLog

private let log = Logger.limpid("review")

struct ReviewTurnTarget {
    let root: URL
    let scope: ReviewScope
    let isTmuxHosted: Bool
}

@MainActor
enum ReviewAgents {
    static func directory(session: WindowSession) -> URL? {
        directory(for: session.activeContainerID, in: session)
    }

    /// The pane review will write to: the one docked below it, while it has a
    /// live surface. A pane closed from another window leaves review open with
    /// nowhere to write, which is the only case that disables insertion.
    static func destination(
        session: WindowSession,
        paneID: UUID?,
        registry: any SurfaceViewProviding
    ) -> ReviewDestination? {
        guard let paneID, let tab = session.tab(containing: paneID),
              registry.deliverer(for: paneID) != nil else { return nil }
        let agent: String? = if tab.agentSessions[.claude]?[paneID] != nil {
            "Claude Code"
        } else if tab.agentSessions[.codex]?[paneID] != nil {
            "Codex"
        } else {
            nil
        }
        // A tab hosting a plain shell carries the command it was started with
        // as its title, which for a tmux-hosted pane is a line of `attach -t`
        // arguments. The directory it works in says more in less room.
        let fallback = directory(for: tab.container, in: session)?.lastPathComponent
        return ReviewDestination(paneID: paneID, title: agent ?? fallback ?? tab.title)
    }

    /// Whether a Review Changes affordance is live, which is not the same
    /// question as whether there is anything to review: the surface can be up
    /// over a container that has nothing, and closing it is the only reading
    /// left. The affordances that asked the narrower question could not close
    /// what the toolbar beside them had opened.
    ///
    /// Here rather than on `ReviewPresentation` because the answer is mostly
    /// about the session; the presentation is optional because it belongs to a
    /// window, and the command palette can be built without one.
    static func canReview(
        session: WindowSession,
        attention: AttentionState,
        presentation: ReviewPresentation?
    ) -> Bool {
        // A surface already up stays up even if the user has since switched to
        // a tab that would not have opened it: the only reading left is to
        // close it, and the affordance is what closes it.
        if presentation?.isPresented == true {
            return true
        }
        guard allowsReviewSurface(session: session) else { return false }
        if directory(session: session) != nil {
            return true
        }
        let paneID = session.activeTab?.splitTree.effectiveFocusedLeafID
        guard isTransientTurnContainer(session: session, paneID: paneID) else { return false }
        return turnTarget(session: session, attention: attention, paneID: paneID) != nil
    }

    /// Whether the active tab lets review dock over it
    /// (`TabCapabilities.canOpenReview`). A session with no active tab keeps
    /// the older answer, since the rest of the check reads the session.
    static func allowsReviewSurface(session: WindowSession) -> Bool {
        session.activeTab?.capabilities.canOpenReview ?? true
    }

    /// The pane review may take when it follows the user onto `tab`: the
    /// tab's focused pane, or `nil` when the tab does not let review dock over
    /// it. Review takes panes implicitly (following focus, following a
    /// container switch), not only when it opens, and a docked mirror pane
    /// would be resized by the strip while tmux keeps sizing the window.
    static func dockablePaneID(in tab: Tab?) -> UUID? {
        guard let tab, tab.capabilities.canOpenReview else { return nil }
        return tab.splitTree.effectiveFocusedLeafID
    }

    static func isTransientTurnContainer(session: WindowSession, paneID: UUID?) -> Bool {
        guard let paneID, let tab = session.tab(containing: paneID) else { return false }
        return tab.container.projectID == nil
    }

    /// The newest usable snapshot badge attached to one pane. Root matching is
    /// performed here so the scope switch and commands cannot offer a tree
    /// captured in another worktree or clone.
    static func turnScope(
        session: WindowSession,
        attention: AttentionState,
        paneID: UUID?,
        root: URL? = nil
    ) -> ReviewScope? {
        turnTarget(session: session, attention: attention, paneID: paneID, root: root)?.scope
    }

    static func turnTarget(
        session: WindowSession,
        attention: AttentionState,
        paneID: UUID?,
        root: URL? = nil
    ) -> ReviewTurnTarget? {
        guard let paneID, let tab = session.tab(containing: paneID) else { return nil }
        let containerRoot = directory(for: tab.container, in: session)?.resolvingSymlinksInPath()
        let requestedRoot = root?.resolvingSymlinksInPath()
        // A project or worktree owns its review even if its shell has changed
        // directory. Letting an explicit turn badge bypass that ownership made
        // Review This Turn and Review Changes open different repositories from
        // the same pane.
        if let containerRoot, let requestedRoot, containerRoot != requestedRoot {
            return nil
        }
        let requiredRoot = containerRoot ?? requestedRoot
        var badges = attention.allRuntimes
            .filter { $0.paneIDs.contains(paneID) }
            .map(\.badge)
        // A provider with no live runtime still has whatever its last record
        // said, which is what the review matches a turn against.
        for (provider, byPane) in tab.agentBadges where attention.runtimesByKind[provider] == nil {
            if let badge = byPane[paneID] {
                badges.append(badge)
            }
        }
        let match = badges
            .filter { badge in
                guard let tree = badge.turnBaseTree, !tree.isEmpty,
                      let path = badge.turnRoot, !path.isEmpty
                else { return false }
                guard let requiredRoot else { return true }
                return URL(fileURLWithPath: path).resolvingSymlinksInPath() == requiredRoot
            }
            .max { $0.updatedAt < $1.updatedAt }
        guard let tree = match?.turnBaseTree, let path = match?.turnRoot else { return nil }
        let turnRoot = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        // A restored tmux client reports the outer shell's OSC 7 directory,
        // not the hosted pane's current directory. The hook ran inside that
        // pane, so its turn root remains the usable evidence for opening; the
        // insertion path performs its own repository check before delivery.
        if tab.container.projectID == nil,
           let workingDirectory = session.workingDirectory(paneID: paneID),
           !isInside(
               URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath(),
               root: turnRoot
           ),
           match?.isTmuxHosted != true
        {
            return nil
        }
        return ReviewTurnTarget(
            root: turnRoot,
            scope: .turn(baseTree: tree, paneID: paneID),
            isTmuxHosted: match?.isTmuxHosted == true
        )
    }

    /// Whether a turn supplied by an attention callback still belongs to the
    /// pane context that will display it. Project and worktree roots are
    /// authoritative; transient containers use the pane's current directory.
    static func canOpenTurn(session: WindowSession, paneID: UUID, root: URL) -> Bool {
        guard let tab = session.tab(containing: paneID) else { return false }
        let normalizedRoot = root.resolvingSymlinksInPath()
        if let containerRoot = directory(for: tab.container, in: session)?.resolvingSymlinksInPath() {
            return containerRoot == normalizedRoot
        }
        guard let workingDirectory = session.workingDirectory(paneID: paneID) else { return true }
        return isInside(
            URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath(),
            root: normalizedRoot
        )
    }

    private static func isInside(_ directory: URL, root: URL) -> Bool {
        let directoryPath = directory.path
        let rootPath = root.path
        return directoryPath == rootPath
            || (rootPath == "/" ? directoryPath.hasPrefix("/") : directoryPath.hasPrefix(rootPath + "/"))
    }

    /// The working directory behind one container. Through `WindowSession`'s
    /// own lookups rather than another `projects.first(where:)` at the call
    /// site, which is what those exist for.
    static func directory(for container: ContainerID, in session: WindowSession) -> URL? {
        switch container {
        case let .project(id):
            session.project(id)?.rootURL
        case let .worktree(projectID, worktreeID):
            session.worktree(projectID: projectID, worktreeID: worktreeID)?.workingDirectory
        default:
            nil
        }
    }

    /// What is running in front on the terminal the text will reach.
    ///
    /// Blocking work — a `sysctl`, and tmux when the pane is hosted there — so
    /// it runs off the main actor and callers poll it rather than reading it
    /// from a view body.
    static func foregroundCommand(
        paneID: UUID,
        registry: any SurfaceViewProviding
    ) async -> String? {
        guard let surfaceTTY = registry.view(for: paneID)?.ttyName else { return nil }
        // A dispatch queue rather than `Task.detached`: this waits on a child
        // process, and blocking a cooperative-pool thread every two seconds is
        // how the whole concurrency runtime runs out of threads.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // The surface's own foreground first: it costs a `sysctl` and
                // it is what says whether the tmux scan is worth starting.
                let surfaceForeground = ReviewTerminalProbe.foregroundProcess(on: surfaceTTY)?.name
                let tty = ReviewTerminalProbe.deliveryTTY(
                    surfaceTTY: surfaceTTY,
                    surfaceForeground: surfaceForeground
                )
                guard tty != surfaceTTY else {
                    continuation.resume(returning: surfaceForeground)
                    return
                }
                continuation.resume(returning: ReviewTerminalProbe.foregroundProcess(on: tty)?.name)
            }
        }
    }

    /// The directory of the terminal that will receive an insertion.
    ///
    /// A restored tmux client keeps reporting the launcher shell's OSC 7
    /// directory on its surface. For a tmux-hosted turn, resolve the active
    /// server pane instead; all other panes use their per-pane OSC 7 value.
    static func insertionWorkingDirectory(
        session: WindowSession,
        paneID: UUID,
        registry: any SurfaceViewProviding,
        isTmuxHosted: Bool
    ) async -> String? {
        guard isTmuxHosted else { return session.workingDirectory(paneID: paneID) }
        guard let surfaceTTY = registry.view(for: paneID)?.ttyName else { return nil }
        let knownBinding = session.tab(containing: paneID)?.tmuxBindings[paneID]
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let foreground = ReviewTerminalProbe.foregroundProcess(on: surfaceTTY)?.name
                continuation.resume(returning: ReviewTerminalProbe.hostedWorkingDirectory(
                    surfaceTTY: surfaceTTY,
                    surfaceForeground: foreground,
                    knownBinding: knownBinding
                ))
            }
        }
    }

    static func insert(
        _ prompt: ReviewPrompt,
        into destination: ReviewDestination,
        registry: any SurfaceViewProviding,
        receipt: ReviewPasteReceipt? = nil
    ) throws {
        guard let target = registry.deliverer(for: destination.paneID) else {
            log.error("insertion refused: no surface for pane \(destination.paneID, privacy: .public)")
            throw ReviewError.targetUnavailable
        }
        // The kernel's accounting name for what the reader is running in that
        // pane. Not always what they typed, but close enough to it to name a
        // project on its own.
        let foreground = destination.foreground ?? "unknown"
        log.notice(
            "inserting review into pane \(destination.paneID, privacy: .public), foreground \(foreground, privacy: .private)"
        )
        try target.deliverReviewText(prompt, receipt: receipt)
    }
}
