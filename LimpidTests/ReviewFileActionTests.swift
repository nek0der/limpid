// ReviewFileActionTests.swift
// Limpid — verifies Review's worktree containment for file actions.

import Foundation
import Testing
@testable import Limpid

struct ReviewFileActionTests {
    @Test("Relative and absolute paths inside the repository resolve canonically")
    func fileURL_relativeAndAbsolutePathsInsideRepository_areAccepted() throws {
        try withTempDir { root in
            let source = root.appendingPathComponent("Sources/Main.swift")
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: source)

            #expect(ReviewFileAction.fileURL(for: "Sources/Main.swift", in: root) == source)
            #expect(ReviewFileAction.fileURL(for: source.path, in: root) == source)
        }
    }

    @Test("A traversal or symlink outside the repository is rejected")
    func fileURL_outsideRepositoryOrSymlinkEscape_isRejected() throws {
        try withTempDir { root in
            let outside = root.deletingLastPathComponent()
                .appendingPathComponent("review-file-action-outside-\(UUID().uuidString)")
            try Data("outside".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }

            let link = root.appendingPathComponent("escape.swift")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            defer { try? FileManager.default.removeItem(at: link) }

            #expect(ReviewFileAction.fileURL(for: "../\(outside.lastPathComponent)", in: root) == nil)
            #expect(ReviewFileAction.fileURL(for: outside.path, in: root) == nil)
            #expect(ReviewFileAction.fileURL(for: "escape.swift", in: root) == nil)
        }
    }
}
