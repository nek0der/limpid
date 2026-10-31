// InitialPromptFile.swift
// Weir — the one-shot files an earlier build's new sessions staged their first instruction in, still delivered and cleaned up.

import Foundation

/// An earlier build's new worktree sheet took a first instruction and
/// handed it to the agent as one argument, never in a shell's program
/// text or an inherited environment: it wrote the text here, 0600 in a
/// 0700 folder, and named the file in the pane's
/// `WEIR_INITIAL_PROMPT_FILE`; the agent's shim takes it on its
/// first launch, deletes it, and passes the text after `--`
/// (`weir_take_initial_prompt` in `agent-shim/runtime-common.sh`).
///
/// The sheet only makes worktrees now, and this build writes no new file.
/// It still reads them, for one release: a tab that build opened behind,
/// whose terminal was never made, is saved with its command and its file
/// (`Tab.initialCommands`, `Tab.initialPromptFiles`), and dropping the file
/// now would start that agent with no instruction, the text silently lost.
/// So the pane is still handed the file, a moved or closed pane still
/// carries or deletes it, and the orphans are still cleaned up.
///
/// Retire the rest of this type, `Tab.initialPromptFiles`, and the shims'
/// `weir_take_initial_prompt` in the release after the one this build
/// ships in, once going back a build means going back past the sheet that
/// wrote them: take the key out of `Tab.CodingKeys`, and a state.json that
/// still has it reads past it.
enum InitialPromptFile {
    /// In the user's own temporary folder, which no other user can list,
    /// one folder a build: a Dev and a Release Weir each clean up their
    /// own (`removeOrphans`). The test host, which is the Dev app, gets a
    /// folder apart, as its data folder is (`WeirPaths`): a test run
    /// must not touch the instructions a running Weir Dev has staged.
    static var defaultDirectory: URL {
        let name = WeirPaths.isRunningInTests ? "weir-prompts-tests" : "weir-prompts-\(WeirPaths.bundleID)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    /// How long a file being taken (`.taken.<pid>`, touched as the shim
    /// takes it) or written (`.tmp-`) may stay: past it, the launch that
    /// took it or the write that made it is over.
    static let staleAfter: TimeInterval = 60 * 60

    /// The variable that names the file. Weir removes it from its own
    /// environment at launch: a Weir started from a pane whose shim has
    /// not run would otherwise hand the pane's instruction to every
    /// process it starts, the quick terminal's shell among them.
    static let environmentKey = "WEIR_INITIAL_PROMPT_FILE"

    /// Deletes the instructions no tab stages any more: a pane closed
    /// before its agent started, an alias that ran the real CLI past the
    /// shim, a launch that never came. Run once the session is restored,
    /// with the files its tabs still stage. A file half taken or half
    /// written goes only when stale.
    static func removeOrphans(keeping staged: Set<String>, in directory: URL = defaultDirectory, now: Date = Date()) {
        let fm = FileManager.default
        // A test host runs the app's launch with the user's data switched
        // on. Its folder is apart from the user's, but test hosts run in
        // parallel and share it: one host's launch must not delete what
        // another host's test has just staged.
        guard !WeirPaths.isRunningInTests || directory != defaultDirectory else { return }
        // By name: the same folder may be spelled two ways (`/var` and
        // `/private/var`), and the name is the file's UUID.
        let stagedNames = Set(staged.map { URL(fileURLWithPath: $0).lastPathComponent })
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard !stagedNames.contains(name) else { continue }
            let isInFlight = name.contains(".taken.") || name.hasPrefix(".")
            if isInFlight {
                let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                guard let modified, now.timeIntervalSince(modified) > staleAfter else { continue }
            }
            try? SecureFileWrite.removeItem(at: url)
        }
    }

    /// Deletes a staged file the pane will never take.
    static func remove(_ path: String?) {
        guard let path else { return }
        try? SecureFileWrite.removeItem(at: URL(fileURLWithPath: path))
    }
}
