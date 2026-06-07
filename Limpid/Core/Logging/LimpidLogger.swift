// LimpidLogger.swift
// Limpid — single factory for every `Logger` in the app. Pins the
// `dev.limpid` subsystem so a category-only callsite never drifts
// onto a typo'd subsystem (the Console.app filter `subsystem ==
// dev.limpid` would silently skip them), and shrinks the per-file
// declaration to `Logger.limpid("category")`.

import OSLog

extension Logger {
    /// Build a `Logger` bound to Limpid's canonical subsystem. Pass a
    /// dot-separated category — the existing convention groups
    /// related call sites (`surface.view`, `claude.session.store`,
    /// `pane.drag`). Adding a new logger means one line at the top of
    /// the file:
    ///
    /// ```swift
    /// private let log = Logger.limpid("my.area")
    /// ```
    static func limpid(_ category: String) -> Logger {
        Logger(subsystem: "dev.limpid", category: category)
    }
}
