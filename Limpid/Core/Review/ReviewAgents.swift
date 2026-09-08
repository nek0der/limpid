// ReviewAgents.swift
// Limpid — resolve where review writes, and write there.

import Foundation
import OSLog

private let log = Logger.limpid("review")

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
        let agent: String? = if tab.claudeSessions[paneID] != nil {
            "Claude Code"
        } else if tab.codexSessions[paneID] != nil {
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
    static func canReview(session: WindowSession, presentation: ReviewPresentation?) -> Bool {
        presentation?.isPresented == true || directory(session: session) != nil
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
