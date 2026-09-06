// CodexShimLocator.swift
// Limpid — resolves the in-bundle `codex-shim/` directory. Mirrors
// `ClaudeShimLocator`'s resolution and stays separate from
// `CodexHookInstaller`: the shim is how hooks reach Codex from here on,
// and outlives the shadow home that used to carry them.

import Foundation

enum CodexShimLocator {
    /// Absolute path of the bundled `codex-shim/` directory, or `nil` when
    /// the bundle does not contain it (a unit-test target with no
    /// Resources phase). Callers treat `nil` as "skip injection".
    static var shimDirectoryURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("codex-shim", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Exposed so the `zdotdir/.zshrc` snippet can re-prepend the shim
    /// after the user's own `.zshrc` runs — the same reason
    /// `LIMPID_SHIM_DIR` exists for Claude. A user line like
    /// `export PATH="/opt/homebrew/bin:$PATH"` would otherwise bury this
    /// directory behind the real `codex` and the hooks would never load.
    static func environment() -> [String: String] {
        guard let shim = shimDirectoryURL else { return [:] }
        return ["LIMPID_CODEX_SHIM_DIR": shim.path]
    }
}
