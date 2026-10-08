// InjectedCommandTitleGuard.swift
// Limpid — recognizes the title a shell reports for a command Limpid
// typed into it, so that title is not taken for one the user chose.

/// One-shot matcher for the title a shell reports immediately before running
/// an app-injected command. Nonmatching prompt titles leave it armed because a
/// slow shell can finish initialization after the command has been submitted.
struct InjectedCommandTitleGuard {
    private var pendingTitle: String?

    mutating func arm(_ title: String) {
        pendingTitle = GhosttyActionRouter.sanitizeInjectedCommandTitle(title)
    }

    mutating func consumeIfMatching(_ title: String) -> Bool {
        guard let pendingTitle else { return false }
        guard GhosttyActionRouter.sanitizeTitle(title) == pendingTitle else { return false }
        self.pendingTitle = nil
        return true
    }

    mutating func clear() {
        pendingTitle = nil
    }
}
