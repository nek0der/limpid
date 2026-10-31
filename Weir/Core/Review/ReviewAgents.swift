// ReviewAgents.swift
// Weir — resolve where review writes, and write there.

import Foundation
import OSLog

private let log = Logger.weir("review")

@MainActor
enum ReviewAgents {
    /// The pane review will write to, while a tab holds it. A pane closed
    /// from another window leaves review open with nowhere to write, which
    /// is the only case that disables insertion. One whose terminal has not
    /// started yet is still one (`ReviewDestination.isLive`): its tab is in
    /// the strip, and the insert starts it.
    static func destination(
        session: WorkspaceSession,
        paneID: UUID?,
        registry: any SurfaceViewProviding
    ) -> ReviewDestination? {
        guard let paneID, let tab = session.tab(containing: paneID) else { return nil }
        // We name the agent the pane runs now, as its badge says, not the resume
        // hint a restored pane keeps: that names an agent that may not have
        // started yet, or one another agent has replaced in front.
        let kind = tab.agentKind(inPane: paneID)
        let agent: String? = switch kind {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case nil: nil
        }
        // A tab hosting a plain shell carries the command it was started with
        // as its title, which for a tmux-hosted pane is a line of `attach -t`
        // arguments. The directory it works in says more in less room.
        let fallback = directory(for: tab.container, in: session)?.lastPathComponent
        return ReviewDestination(
            paneID: paneID,
            title: agent ?? fallback ?? tab.title,
            agent: kind,
            isLive: registry.deliverer(for: paneID)?.isReadyForReviewPaste == true
        )
    }

    /// The working directory behind one container. Through `WorkspaceSession`'s
    /// own lookups rather than another `projects.first(where:)` at the call
    /// site, which is what those exist for.
    static func directory(for container: ContainerID, in session: WorkspaceSession) -> URL? {
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
        return await offMain {
            // The surface's own foreground first: it costs a `sysctl` and
            // it is what says whether the tmux scan is worth starting.
            let surfaceForeground = ReviewTerminalProbe.foregroundProcess(on: surfaceTTY)?.name
            let tty = ReviewTerminalProbe.deliveryTTY(
                surfaceTTY: surfaceTTY,
                surfaceForeground: surfaceForeground
            )
            guard tty != surfaceTTY else { return surfaceForeground }
            return ReviewTerminalProbe.foregroundProcess(on: tty)?.name
        }
    }

    /// What is running in front on each of `paneIDs`' terminals, as
    /// `foregroundCommand` reads one, for the destination menu's other
    /// panes: every surface asked of the kernel in one hop off the main
    /// actor, and tmux's clients listed once, in a second, for the panes
    /// that host one. A pane with no terminal yet is not in the answer.
    /// `nil` once the task is canceled, so a pass cut short writes nothing.
    static func foregroundCommands(paneIDs: [UUID], registry: any SurfaceViewProviding) async -> [UUID: String]? {
        guard !Task.isCancelled else { return nil }
        let surfaces = paneIDs.compactMap { paneID in registry.view(for: paneID)?.ttyName.map { (paneID, $0) } }
        let ttys = surfaces.map(\.1)
        let names = await offMain { ttys.map { ReviewTerminalProbe.foregroundProcess(on: $0)?.name } }
        guard !Task.isCancelled else { return nil }
        var foregrounds: [UUID: String] = [:]
        var hosted: [(paneID: UUID, tty: String)] = []
        for ((paneID, tty), name) in zip(surfaces, names) {
            if name == TmuxClientProbe.clientProcessName {
                hosted.append((paneID, tty))
            } else {
                foregrounds[paneID] = name
            }
        }
        guard !hosted.isEmpty else { return foregrounds }
        let hostedTTYs = hosted.map(\.tty)
        let inTmux = await offMain { ReviewTerminalProbe.hostedForegrounds(surfaceTTYs: hostedTTYs) }
        guard !Task.isCancelled else { return nil }
        for (paneID, tty) in hosted {
            foregrounds[paneID] = inTmux[tty]
        }
        return foregrounds
    }

    /// `work` on a dispatch queue rather than `Task.detached`: it waits on
    /// a `sysctl` or a child process, and blocking a cooperative-pool thread
    /// every two seconds is how the whole concurrency runtime runs out of
    /// threads.
    private nonisolated static func offMain<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
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
