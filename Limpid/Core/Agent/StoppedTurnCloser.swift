// StoppedTurnCloser.swift
// Limpid — writes the end of a turn the person stopped where no hook says so, off the main actor and once per turn.

import Foundation
import OSLog

private let log = Logger.limpid("agent.stopped-turn")

/// Runs the projection's `endStoppedTurn` commands: Claude sends no hook
/// when the person declines its question or permission prompt with Esc or
/// "No", nor when they stop its work with Esc or Ctrl+C, so the pass that
/// reads the stop from Claude's own status report or from the transcript
/// asks for the run record and its turn to be ended, which the bridge's
/// writer does as the hook would (`LimpidTurnBridge.endStoppedTurn`).
///
/// The projection asks again on every pass until the record says the turn
/// stopped, so this keeps which turns it has asked for: each is written
/// once, and one whose write did not land (a hook held the lock, the
/// transcript could not be read) is tried again on a later pass, at most
/// `maximumAttempts` times. Until then the badge alone shows the turn
/// stopped. The writer runs git for the turn's end snapshot and may wait a
/// second for the transcript, so it runs on a queue of its own rather than
/// the shared pool or the main actor.
@MainActor
final class StoppedTurnCloser {
    typealias Apply = @Sendable (StoppedTurnRequest) throws -> StoppedTurnEnd

    /// This is how many times one turn is tried. A turn whose write keeps
    /// failing stays shown stopped by the badge, and its next prompt writes
    /// the record anyway; trying on every pass would run git each time.
    static let maximumAttempts = 3

    private let apply: Apply
    private let queue = DispatchQueue(label: "dev.limpid.stopped-turn", qos: .userInitiated)
    /// This counts the tries made for each turn a pass still asks about.
    private var attempts: [StoppedTurnRequest: Int] = [:]
    /// These are the turns nothing is left to try for (`StoppedTurnEnd.isSettled`).
    private var settled: Set<StoppedTurnRequest> = []
    /// These are the writes on their way, by turn.
    private var inFlight: [StoppedTurnRequest: Task<Void, Never>] = [:]

    init(apply: @escaping Apply = { try LimpidTurnBridge.endStoppedTurn($0) }) {
        self.apply = apply
    }

    /// Takes the turns one pass asked to end. A turn no longer asked about is
    /// forgotten: its record moved on, so what was tried for it says
    /// nothing about the next one. `ended` runs on the main actor once a
    /// write lands, so the host can read the records again at once.
    func close(_ requests: [StoppedTurnRequest], ended: @escaping @MainActor () -> Void) {
        let asked = Set(requests)
        attempts = attempts.filter { asked.contains($0.key) || inFlight[$0.key] != nil }
        settled.formIntersection(asked)
        for request in asked
            where !settled.contains(request) && inFlight[request] == nil
            && attempts[request, default: 0] < Self.maximumAttempts
        {
            attempts[request, default: 0] += 1
            let apply = apply
            let queue = queue
            inFlight[request] = Task { [weak self] in
                let outcome = await Self.run(apply, request, on: queue)
                guard let self else { return }
                inFlight[request] = nil
                if outcome.isSettled {
                    settled.insert(request)
                }
                if outcome == .ended {
                    ended()
                }
            }
        }
    }

    /// Waits until no write is on its way. It is for tests, which otherwise
    /// cannot tell when a write has landed.
    func writesSettled() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    private nonisolated static func run(
        _ apply: @escaping Apply,
        _ request: StoppedTurnRequest,
        on queue: DispatchQueue
    ) async -> StoppedTurnEnd {
        await withCheckedContinuation { continuation in
            queue.async {
                let outcome: StoppedTurnEnd
                do {
                    outcome = try apply(request)
                } catch {
                    log.error("stopped turn not ended: \(String(describing: error), privacy: .private)")
                    outcome = .failed
                }
                if outcome != .ended {
                    log.info("stopped turn of \(request.storageID, privacy: .public) not ended: \(outcome.rawValue, privacy: .public)")
                }
                continuation.resume(returning: outcome)
            }
        }
    }
}

extension StoppedTurnRequest {
    /// Returns the turns `commands` ask to end (`endStoppedTurn`), each
    /// with the state directory of its record's provider. A turn for a
    /// provider this build has no directories for is left out.
    static func asked(
        by commands: [AgentProjectionCommand],
        in directories: [String: AgentDirectories]
    ) -> [StoppedTurnRequest] {
        commands.compactMap { command in
            guard case let .endStoppedTurn(episodeToken, turnID, transcriptPath, byProgramStatus) = command.op,
                  case let .record(provider, storageID) = command.target,
                  let state = directories[provider]?.state
            else { return nil }
            return StoppedTurnRequest(
                provider: provider,
                stateDirectory: state,
                storageID: storageID,
                episodeToken: episodeToken,
                turnID: turnID,
                transcriptPath: transcriptPath,
                byProgramStatus: byProgramStatus
            )
        }
    }
}
