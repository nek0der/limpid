// GitStatus.swift
// Limpid — branch, upstream, and changed entries for a single working tree,
// parsed from the `git status --porcelain=v2 --branch` the facts read runs.
// The porcelain v2 header contains everything we need so we don't have
// to chain multiple commands:
//
//   # branch.oid abc123…
//   # branch.head main
//   # branch.upstream origin/main
//   # branch.ab +0 -2
//   1 .M N… <path>
//   ? <path>
//
// Each `1 ...`, `2 ...`, `u ...`, or `?` line is one changed entry.

import Foundation

struct GitWorktreeStatus: Equatable {
    var branch: String?
    var upstream: String?
    /// The entries `git status` listed, each one a changed, renamed,
    /// unmerged, or untracked path.
    var changedEntries = 0
    /// Whether ahead and behind counts were reported: not without an
    /// upstream, nor when the upstream branch is gone from the remote.
    var hasAheadBehind = false
}

enum GitStatus {
    /// Parse porcelain-v2 status output. Returns a status struct even
    /// when there are no header lines; fields just stay at their
    /// defaults.
    static func parse(_ porcelain: String) -> GitWorktreeStatus {
        var status = GitWorktreeStatus()
        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.head ") {
                let name = String(line.dropFirst("# branch.head ".count))
                if name != "(detached)" {
                    status.branch = name
                }
            } else if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // Format: "+N -N"
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 {
                    status.hasAheadBehind = true
                }
            } else if line.hasPrefix("1 ")
                || line.hasPrefix("2 ")
                || line.hasPrefix("u ")
                || line.hasPrefix("? ")
            {
                status.changedEntries += 1
            }
        }
        return status
    }
}
