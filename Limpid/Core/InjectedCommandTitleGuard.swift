// InjectedCommandTitleGuard.swift
// Limpid — recognizes the title a shell reports for a command Limpid
// typed into it, so that title is not taken for one the user chose.

/// Matches the title a shell reports for a command Limpid typed: the
/// shell's preexec hook names the command line as the title the moment it
/// runs it, and Limpid's own commands stay out of a tab's name. The guard
/// holds the command for as long as the command may run: nonmatching
/// prompt titles leave it armed, because a slow shell can finish
/// initialization after the command has been submitted, and a matching
/// title leaves it armed too, because a shell with more than one hook
/// reports the same command more than once. Every command typed is held,
/// not only the last: a line typed to the agent's TUI meanwhile (the
/// prompt cache panel's `/compact`) must not let the resume's title
/// through. They are let go when a command has finished (`clear()`), the
/// one boundary after which such a title would be the person's own.
struct InjectedCommandTitleGuard {
    private var pendingTitles: Set<String> = []

    mutating func arm(_ title: String) {
        pendingTitles.insert(GhosttyActionRouter.sanitizeInjectedCommandTitle(title))
    }

    /// Whether `title` is a held command's, read with the same sanitization
    /// every incoming title gets.
    func matches(_ title: String) -> Bool {
        !pendingTitles.isEmpty && pendingTitles.contains(GhosttyActionRouter.sanitizeTitle(title))
    }

    mutating func clear() {
        pendingTitles.removeAll()
    }
}
