// AppState+Terminate.swift
// Limpid — everything that has to reach disk before the process exits.
//
// Split out of `AppState.init` because that initializer was already at
// the length the linter allows and this is the part of it with the
// clearest boundary: one notification, one ordered flush, no state of
// its own. Only the ⌘Q path runs it — a crash keeps whatever the last
// debounced autosave wrote, which excludes scrollback and tmux
// bindings by design.

import AppKit
import Foundation

extension AppState {
    /// Install the `willTerminate` flush and return its observer token
    /// for `deinit` to remove.
    ///
    /// Ordering matters twice over. The two captures run before the
    /// snapshot because both write into `session`. And
    /// `preserveLiveSessionsOnTerminate` runs before the save so the
    /// records it edits are the ones that land.
    ///
    /// Every collaborator is read into a local first. The observer is
    /// stored back on `self`, so a closure that reached through `self`
    /// for them would keep the whole `AppState` alive through its own
    /// token; capturing the values breaks that.
    func installTerminateHandler() -> Any {
        let store = self.store
        let historyStore = self.historyStore
        let frecencyStore = self.frecencyStore
        let settingsStore = self.settingsStore
        let registry = self.registry
        let codexAgentStateTracker = self.codexAgentStateTracker
        return NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let session = self?.session else { return }
            MainActor.assumeIsolated {
                // Ask libghostty to dump every live surface's scrollback
                // to disk so the next launch can replay it.
                session.captureScrollbackPaths(from: registry)
                // And which tmux session each pane was showing, so the
                // next launch reattaches instead of leaving it running
                // unreferenced beside a fresh shell.
                session.captureTmuxBindings(from: registry)
                // Blank out the `pid` field on every codex state record
                // that points at a still-running codex. Limpid is about to
                // kill those processes alongside its own exit; without
                // this step the next launch's PID sweep would mistake the
                // forced kill for a `/quit` and drop the resume record.
                // Records whose codex already exited (user typed `/quit`
                // before ⌘Q) keep their dead pid → sweep deletes →
                // session correctly not restored.
                codexAgentStateTracker.preserveLiveSessionsOnTerminate()
                store.saveSynchronously(session.makeSnapshot())
                historyStore.flushSynchronously()
                frecencyStore.flushSynchronously()
                // Flush any pending settings.json write — a slider tick
                // or accent pick inside the 250 ms debounce window would
                // otherwise be cancelled as the process tears down.
                settingsStore.flushSynchronously()
            }
        }
    }
}
