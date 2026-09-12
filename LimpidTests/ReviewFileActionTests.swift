// ReviewFileActionTests.swift
// Limpid — verifies Review's application preference and worktree containment.

import Foundation
import Testing
@testable import Limpid

struct ReviewFileActionTests {
    private let application = ReviewFileApplication(
        bundleIdentifier: "com.example.ReviewEditor",
        lastKnownDisplayName: "Review Editor"
    )

    @Test("An unset review app leaves file handling to macOS")
    func application_unsetUsesMacOSDefault() {
        let resolution = ReviewFileAction.application(for: nil) { _ in nil }

        #expect(resolution == .macOSDefault)
        #expect(resolution.displayName == nil)
    }

    @Test("A configured bundle identifier is resolved when the action runs")
    func application_configuredResolvesBundleIdentifier() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Review Editor.app")
        let resolution = ReviewFileAction.application(for: application) { identifier in
            #expect(identifier == "com.example.ReviewEditor")
            return bundleURL
        }

        #expect(resolution == .configured(application, bundleURL: bundleURL))
        #expect(resolution.displayName == "Review Editor")
    }

    @Test("A missing app preserves its last-known name and remains distinguishable")
    func application_missingKeepsPreference() {
        let resolution = ReviewFileAction.application(for: application) { _ in nil }

        #expect(resolution == .configuredApplicationMissing(application))
        #expect(resolution.displayName == "Review Editor")
    }

    @Test("A future app preference field survives a read and write")
    func application_unknownFieldsRoundTrip() throws {
        let data = Data(#"{"bundleIdentifier":"com.example.ReviewEditor","lastKnownDisplayName":"Review Editor","future":"value"}"#.utf8)

        let decoded = try JSONDecoder().decode(ReviewFileApplication.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(object?["future"] as? String == "value")
    }

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
