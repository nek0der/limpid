// WeirLogger.swift
// Weir — single factory for every `Logger` in the app. Pins the
// `com.nekoder.weir` subsystem so a category-only callsite never drifts
// onto a typo'd subsystem (the Console.app filter `subsystem ==
// com.nekoder.weir` would silently skip them), and shrinks the per-file
// declaration to `Logger.weir("category")`.

import OSLog

extension Logger {
    /// Build a `Logger` bound to Weir's canonical subsystem. Pass a
    /// dot-separated category — the existing convention groups
    /// related call sites (`surface.view`, `claude.session.store`,
    /// `pane.drag`). Adding a new logger means one line at the top of
    /// the file:
    ///
    /// ```swift
    /// private let log = Logger.weir("my.area")
    /// ```
    static func weir(_ category: String) -> Logger {
        Logger(subsystem: "com.nekoder.weir", category: category)
    }
}
