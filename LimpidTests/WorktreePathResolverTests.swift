// WorktreePathResolverTests.swift
// Limpid — a worktree path is resolved through its links once, and let go of with its project.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct WorktreePathResolverTests {
    @Test func aLinkedFolder_resolvesToItsTarget() throws {
        try withTempDir { dir in
            let real = dir.appendingPathComponent("real")
            let link = dir.appendingPathComponent("link")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
            let paths = WorktreePathResolver()

            #expect(paths.resolved(link.path) == real.resolvingSymlinksInPath().path)
            #expect(paths.resolved(link.path) == paths.resolved(real.path), "both spellings are one worktree's records")
            #expect(paths.isRoot(real.path)(link.path), "the link names the worktree it points at")
        }
    }

    @Test func eachSpelling_isResolvedOnce_untilItsFolderIsForgotten() {
        var resolutions: [String] = []
        let paths = WorktreePathResolver { path in
            resolutions.append(path)
            return path.replacingOccurrences(of: "/link", with: "/real")
        }

        #expect(paths.resolved("/tmp/link") == "/tmp/real")
        #expect(paths.resolved("/tmp/link") == "/tmp/real")
        #expect(resolutions == ["/tmp/link"], "the second call reads what the first resolved")

        paths.forget(["/elsewhere"])
        _ = paths.resolved("/tmp/link")
        #expect(resolutions == ["/tmp/link"], "another folder's removal keeps it")

        paths.forget(["/tmp/real"])
        _ = paths.resolved("/tmp/link")
        #expect(resolutions == ["/tmp/link", "/tmp/link"], "its project's removal lets it go")
    }
}
