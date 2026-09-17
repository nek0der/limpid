// TmuxRestoredBindingProbeTests.swift
// Limpid — how the launch check questions the sockets a restored session names.

import Foundation
import Testing
@testable import Limpid

/// Records how the launch check called a probe: which sockets it asked,
/// and how many questions were in flight at once.
private final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    private var inFlight = 0
    private var peak = 0

    var askedSockets: [String] {
        lock.withLock { asked }
    }

    var peakInFlight: Int {
        lock.withLock { peak }
    }

    func begin(_ socketPath: String) {
        lock.withLock {
            asked.append(socketPath)
            inFlight += 1
            peak = max(peak, inFlight)
        }
    }

    func end() {
        lock.withLock { inFlight -= 1 }
    }
}

@Suite("restored binding probe")
@MainActor
struct TmuxRestoredBindingProbeTests {
    /// A session whose leaves carry `count` bindings, each on its own
    /// socket, the way an older `state.json` saved them.
    private func restoredSession(sockets: Int) -> (session: WindowSession, store: TmuxConnectionStore) {
        let session = WindowSession()
        for index in 0..<sockets {
            let tab = session.openTab(container: .loose)
            guard let leafID = session.tab(tab.id)?.splitTree.allLeafIDs().first else { continue }
            session.update(tab.id) { t in
                t.tmuxBindings[leafID] = TmuxBinding(
                    socketPath: "/tmp/limpid-none/sock-\(index)",
                    sessionID: "$\(index)",
                    sessionName: "s\(index)"
                )
            }
        }
        // No tmux path, so nothing here reaches a real server: the probe
        // answers for every socket and the reconnect that follows does
        // nothing.
        let store = TmuxConnectionStore(
            registry: RecordingSurfaceRegistry(),
            secureInput: nil,
            tmuxExecutable: nil
        )
        return (session, store)
    }

    /// A server that takes `delay` to answer and says it has no session, so
    /// every claim is dropped and the plan is the same however the answers
    /// are interleaved.
    private func slowProbe(_ recorder: ProbeRecorder, delay: Duration) -> TmuxMirrorActions.RestoredBindingProbe {
        TmuxMirrorActions.RestoredBindingProbe(
            sessions: { socketPath in
                recorder.begin(socketPath)
                try? await Task.sleep(for: delay)
                recorder.end()
                return .sessions([])
            },
            panes: { _, _ in nil }
        )
    }

    /// A server that stopped answering costs its query the whole timeout,
    /// and asking four of them one after the other leaves every restored
    /// pane without a surface for four of those.
    @Test("the sockets of a restored session are asked at once")
    func reconcileRestoredBindings_asksTheSocketsInParallel() async {
        let (session, store) = restoredSession(sockets: 4)
        let recorder = ProbeRecorder()

        await TmuxMirrorActions.reconcileRestoredBindings(
            session: session,
            store: store,
            probe: slowProbe(recorder, delay: .milliseconds(100))
        )?.value

        #expect(recorder.peakInFlight == 4)
        #expect(recorder.askedSockets.sorted() == (0..<4).map { "/tmp/limpid-none/sock-\($0)" })
    }

    /// Whatever the order the answers come back in, each socket is asked
    /// once and every claim is settled: the check ends and the bindings a
    /// server does not have are gone from the tabs.
    @Test("each socket is asked once, and the plan is the one a serial pass produced")
    func reconcileRestoredBindings_settlesEveryClaimOnce() async {
        let (session, store) = restoredSession(sockets: 3)
        // Two leaves of the same tab share one socket, which must still
        // cost one question.
        let extraTab = session.tabs[0]
        let extraLeaf = UUID()
        session.update(extraTab.id) { t in
            t.tmuxBindings[extraLeaf] = TmuxBinding(
                socketPath: "/tmp/limpid-none/sock-0",
                sessionID: "$9",
                sessionName: "s9"
            )
        }
        let recorder = ProbeRecorder()

        await TmuxMirrorActions.reconcileRestoredBindings(
            session: session,
            store: store,
            probe: slowProbe(recorder, delay: .milliseconds(10))
        )?.value

        #expect(recorder.askedSockets.sorted() == (0..<3).map { "/tmp/limpid-none/sock-\($0)" })
        #expect(session.tabs.filter { !$0.tmuxBindings.isEmpty }.isEmpty)
        #expect(!store.isAwaitingRestoreCheck(extraLeaf))
    }
}
