// ReviewSession+Refresh.swift
// Limpid — the review's Refresh as tests drive it: the same reload the app runs.

@testable import Limpid

extension ReviewSession {
    /// What Refresh does (`ReviewWorkspaceView.refresh()`), for a review
    /// whose tab asks for the scope already loaded: reads that scope again,
    /// keeping the open file when it is still listed. Through
    /// `reload` rather than a list-only read of its own, so a test exercises
    /// the path the app takes. After a change of scope that failed, the app
    /// reads the scope the tab asked for instead.
    @discardableResult
    func refreshAsTheAppDoes() async -> ReviewReloadResult {
        await reload(selectedFileID: diff?.file.id)
    }
}
