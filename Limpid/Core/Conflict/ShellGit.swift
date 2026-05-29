// ShellGit.swift
// Limpid — production `GitInspecting` that shells out via the existing
// `GitProcess` wrapper. We reuse `GitProcess.run` (rather than a fresh
// Process) so the conflict pipeline inherits its hard-won setup: PATH
// resolution through `/usr/bin/env git`, the `LC_ALL=C` locale pin, and
// the background-queue dispatch.

import Foundation

struct ShellGit: GitInspecting {
    func status(at root: URL) async throws -> [GitStatusEntry] {
        // `--porcelain=v1 -z`: machine-readable, NUL-separated so paths
        //   containing spaces / newlines / non-ASCII survive verbatim.
        // `--untracked-files=all`: surface brand-new files too; git
        //   still drops `.gitignore`d paths, so build output stays out.
        let result = try await GitProcess.run(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            cwd: root
        )
        // A non-zero exit means "not a working tree" or a transient git
        // error — treat as "no changes" rather than throwing, matching
        // how `GitStatus.fetch` returns nil for non-repos. The caller
        // (a per-worktree watcher) re-runs on the next FS event anyway.
        guard result.succeeded else { return [] }
        return Self.parse(result.stdout)
    }

    /// Parse `git status --porcelain=v1 -z` output. Each record is
    /// `XY<SP><path>` terminated by NUL; rename / copy records append a
    /// second NUL-separated field carrying the original path. Splitting
    /// on NUL yields a trailing empty element we skip.
    ///
    /// Pulled out as a pure static so the parser is unit-testable
    /// without spawning git — `git status` quoting / rename ordering is
    /// exactly the kind of thing that silently regresses.
    static func parse(_ porcelain: String) -> [GitStatusEntry] {
        let tokens = porcelain
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)

        var entries: [GitStatusEntry] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            // Minimum well-formed record is `XY p` (two status chars, a
            // separating space, at least one path char). The trailing
            // empty tail and any stray short token fall through here.
            guard token.count >= 4 else { continue }

            let chars = Array(token)
            let x = chars[0]
            // chars[1] is Y, chars[2] is the separating space; the path
            // begins at offset 3.
            let path = String(chars[3...])
            // Staged = the index column carries a real status. Untracked
            // (`?`) and "worktree-only" (` M`) changes are not staged.
            let staged = x != " " && x != "?"

            // Rename (`R`) / copy (`C`) in either column carries the
            // original path as the next NUL-separated field.
            var renamedFrom: String?
            if x == "R" || x == "C" || chars[1] == "R" || chars[1] == "C" {
                if index < tokens.count {
                    renamedFrom = tokens[index]
                    index += 1
                }
            }

            entries.append(
                GitStatusEntry(path: path, renamedFrom: renamedFrom, staged: staged)
            )
        }
        return entries
    }
}
