// ShellCommandInstallerTests.swift
// Weir — the link the shell command is installed as, and the bundled script.

import Foundation
import Synchronization
import Testing
@testable import Weir

struct ShellCommandInstallerTests {
    private final class Recorder: Sendable {
        private let calls = Mutex<[[String]]>([])

        var recorded: [[String]] {
            calls.withLock(\.self)
        }

        func record(_ arguments: [String]) {
            calls.withLock { $0.append(arguments) }
        }
    }

    /// A fake app holding a script, and a link path beside it in `bin`.
    private func installer(
        in directory: URL,
        recorder: Recorder = Recorder(),
        result: ToolResult? = ToolResult(exitCode: 0, stdout: "", stderr: "")
    ) throws -> ShellCommandInstaller {
        let manager = FileManager.default
        let script = directory.appendingPathComponent("Weir.app/Contents/Resources/cli/weir")
        try manager.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: script)
        return ShellCommandInstaller(
            script: script,
            link: directory.appendingPathComponent("bin/weir"),
            runOsascript: { arguments in
                recorder.record(arguments)
                return result
            }
        )
    }

    @Test func install_writableFolder_linksWithoutAskingForAnAdministrator() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            #expect(subject.status() == .notInstalled)

            try await subject.install(prompt: "prompt")

            #expect(subject.status() == .installed)
            #expect(recorder.recorded.isEmpty)
        }
    }

    @Test func uninstall_ownLink_removesIt() async throws {
        try await withTempDir { directory in
            let subject = try installer(in: directory)
            try await subject.install(prompt: "prompt")

            try await subject.uninstall(prompt: "prompt")

            #expect(subject.status() == .notInstalled)
        }
    }

    @Test func status_linkToAMovedCopyOfWeir_isStaleAndInstallReplacesIt() async throws {
        try await withTempDir { directory in
            let subject = try installer(in: directory)
            let manager = FileManager.default
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: subject.link.path, withDestinationPath: "/gone/Weir.app/Contents/Resources/cli/weir")
            #expect(subject.status() == .staleLink)

            try await subject.install(prompt: "prompt")

            #expect(subject.status() == .installed)
        }
    }

    @Test func status_linkToAnotherCopyOfWeir_isStale() throws {
        try withTempDir { directory in
            let subject = try installer(in: directory)
            let manager = FileManager.default
            let other = directory.appendingPathComponent("Other/Weir.app/Contents/Resources/cli/weir")
            try manager.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: other)
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: subject.link, withDestinationURL: other)

            #expect(subject.status() == .staleLink)
        }
    }

    @Test func install_someoneElsesFile_refusesAndKeepsIt() async throws {
        try await withTempDir { directory in
            let subject = try installer(in: directory)
            let manager = FileManager.default
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("theirs".utf8).write(to: subject.link)
            #expect(subject.status() == .occupied)

            await #expect(throws: ShellCommandError.installFailed) {
                try await subject.install(prompt: "prompt")
            }
            await #expect(throws: ShellCommandError.uninstallFailed) {
                try await subject.uninstall(prompt: "prompt")
            }

            #expect(try Data(contentsOf: subject.link) == Data("theirs".utf8))
        }
    }

    @Test func status_danglingLinkOfAnotherTool_isOccupied() throws {
        try withTempDir { directory in
            let subject = try installer(in: directory)
            let manager = FileManager.default
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: subject.link.path, withDestinationPath: "/Volumes/Gone/bin/weir")

            #expect(subject.status() == .occupied)
        }
    }

    @Test func status_linkToSomeoneElsesTool_isOccupied() throws {
        try withTempDir { directory in
            let subject = try installer(in: directory)
            let manager = FileManager.default
            let tool = directory.appendingPathComponent("other-tool")
            try Data().write(to: tool)
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: subject.link, withDestinationURL: tool)

            #expect(subject.status() == .occupied)
        }
    }

    /// A folder that refuses the link stands in for a root-owned
    /// `/usr/local/bin`.
    private func withReadOnlyLinkFolder(of subject: ShellCommandInstaller, _ body: () async throws -> Void) async throws {
        let manager = FileManager.default
        let folder = subject.link.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        try await body()
    }

    @Test func install_folderRefusesLink_passesPathsAsArgumentsToTheAdministratorStep() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.install(prompt: "prompt")
            }

            let arguments = try #require(recorder.recorded.first)
            #expect(Array(arguments.suffix(4)) == [
                subject.link.deletingLastPathComponent().path, subject.script.path, subject.link.path, "prompt"
            ])
            let source = arguments.dropLast(4).joined(separator: "\n")
            #expect(source.contains("with administrator privileges"))
            #expect(source.contains("/bin/ln -sn "))
            #expect(!source.contains(subject.script.path))
        }
    }

    @Test func install_promptDismissed_returnsWithoutAFailure() async throws {
        try await withTempDir { directory in
            let subject = try installer(
                in: directory,
                result: ToolResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
            )

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.install(prompt: "prompt")
            }
        }
    }

    @Test func install_administratorStepFails_throws() async throws {
        try await withTempDir { directory in
            let subject = try installer(
                in: directory,
                result: ToolResult(exitCode: 1, stdout: "", stderr: "execution error: not allowed (1)")
            )

            try await withReadOnlyLinkFolder(of: subject) {
                await #expect(throws: ShellCommandError.installFailed) {
                    try await subject.install(prompt: "prompt")
                }
            }
        }
    }

    @Test func install_overStaleLink_forcesOnlyThatLink() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            let manager = FileManager.default
            try manager.createDirectory(at: subject.link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: subject.link.path, withDestinationPath: "/gone/Weir.app/Contents/Resources/cli/weir")

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.install(prompt: "prompt")
            }

            let arguments = try #require(recorder.recorded.first)
            #expect(arguments.joined(separator: "\n").contains("/bin/ln -sfn "))
        }
    }

    @Test func uninstall_folderRefuses_asksAnAdministratorToRemoveTheLink() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let subject = try installer(in: directory, recorder: recorder)
            try await subject.install(prompt: "prompt")

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.uninstall(prompt: "prompt")
            }

            let arguments = try #require(recorder.recorded.first)
            #expect(Array(arguments.suffix(2)) == [subject.link.path, "prompt"])
            #expect(arguments.joined(separator: "\n").contains("/bin/rm -f "))
        }
    }

    /// Runs the real AppleScript without its administrator clause, so that a
    /// syntax slip or a quoting hole shows on paths built to expose one.
    @Test func administratorScript_hostilePaths_linksExactlyThosePaths() async throws {
        try await withTempDir { directory in
            let recorder = Recorder()
            let hostile = directory.appendingPathComponent("it's $(touch pwned) \"x\"")
            let subject = try installer(in: hostile, recorder: recorder)

            try await withReadOnlyLinkFolder(of: subject) {
                try await subject.install(prompt: "prompt")
            }
            let arguments = try #require(recorder.recorded.first)
            let clause = " with prompt item -1 of argv with administrator privileges"
            #expect(arguments.contains { $0.contains(clause) })
            let unprivileged = arguments.map { $0.replacingOccurrences(of: clause, with: "") }
            #expect(!unprivileged.contains { $0.contains("administrator") })

            let result = try #require(await runTool(
                executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: unprivileged,
                workingDirectory: directory,
                timeout: .seconds(30)
            ))

            #expect(result.isSuccess, "\(result.stderr)")
            #expect(subject.status() == .installed)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("pwned").path))
        }
    }

    @Test func promptWordsInAFailure_digitsInAPathAreNotACancellation() async throws {
        try await withTempDir { directory in
            let subject = try installer(
                in: directory,
                result: ToolResult(exitCode: 1, stdout: "", stderr: "ln: /Applications/Weir-128.app: File exists (1)")
            )

            try await withReadOnlyLinkFolder(of: subject) {
                await #expect(throws: ShellCommandError.installFailed) {
                    try await subject.install(prompt: "prompt")
                }
            }
        }
    }

    @Test func bundledScript_declaresTheSamePathAsTheInstaller() throws {
        let subject = try #require(ShellCommandInstaller.forThisApp)
        let source = try String(contentsOf: subject.script, encoding: .utf8)

        #expect(source.contains("bundled_path=/\(ShellCommandInstaller.bundledPath)\n"))
    }
}

struct ShellCommandRowTests {
    private func row(_ status: ShellCommandStatus, readOnly: Bool = false) -> ShellCommandRow {
        ShellCommandRow(status: status, path: "/usr/local/bin/weir", isAppOnReadOnlyVolume: readOnly)
    }

    @Test func actions_followTheStatus() {
        #expect(row(.notInstalled).actions == [.install])
        #expect(row(.installed).actions == [.uninstall])
        #expect(row(.staleLink).actions == [.repair, .uninstall])
        #expect(row(.occupied).actions == [.showInFinder])
    }

    /// A link into a disk image would break when the image is ejected, but a
    /// link already there can still be removed.
    @Test func readOnlyVolume_offersNothingThatLinksHere() {
        #expect(row(.notInstalled, readOnly: true).actions.isEmpty)
        #expect(row(.staleLink, readOnly: true).actions == [.uninstall])
        #expect(row(.installed, readOnly: true).actions == [.uninstall])
    }
}

/// Runs the script the app ships, in a fake bundle, with `open` replaced by
/// one that records what it was given.
struct WeirShellScriptTests {
    private struct Run {
        let exitCode: Int32
        let opened: [String]?
        let stderr: String
    }

    private func bundledScript() throws -> URL {
        try #require(ShellCommandInstaller.forThisApp).script
    }

    private func run(
        _ arguments: [String],
        from workingDirectory: URL? = nil,
        in directory: URL
    ) async throws -> (Run, app: URL) {
        let manager = FileManager.default
        let app = directory.appendingPathComponent("My Weir.app")
        let script = app.appendingPathComponent("Contents/Resources/cli/weir")
        try manager.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: bundledScript(), to: script)
        let fakeBin = directory.appendingPathComponent("fake-bin")
        let record = directory.appendingPathComponent("opened.txt")
        try manager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeOpen = fakeBin.appendingPathComponent("open")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(record.path)'\n".utf8).write(to: fakeOpen)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
        // Through a link, as the command is run once installed.
        let link = directory.appendingPathComponent("weir-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: script)
        let result = try #require(await runTool(
            executable: link,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: ["PATH": "\(fakeBin.path):/usr/bin:/bin"],
            timeout: .seconds(30)
        ))
        let opened = (try? String(contentsOf: record, encoding: .utf8))
            .map { $0.split(separator: "\n").map(String.init) }
        return (Run(exitCode: result.exitCode, opened: opened, stderr: result.stderr), app)
    }

    @Test func dot_opensTheWorkingDirectoryInTheAppItShipsIn() async throws {
        try await withTempDir { directory in
            let project = directory.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

            let (run, app) = try await run(["."], from: project, in: directory)

            #expect(run.exitCode == 0)
            #expect(run.opened?.first == "-a")
            #expect(run.opened?.count == 3)
            let opened = try #require(run.opened)
            #expect(URL(fileURLWithPath: opened[1]).resolvingSymlinksInPath() == app.resolvingSymlinksInPath())
            #expect(URL(fileURLWithPath: opened[2]).resolvingSymlinksInPath() == project.resolvingSymlinksInPath())
        }
    }

    @Test func noArguments_opensJustTheApp() async throws {
        try await withTempDir { directory in
            let (run, _) = try await run([], in: directory)

            #expect(run.exitCode == 0)
            #expect(run.opened?.count == 2)
        }
    }

    @Test func folderNamedLikeAnOption_afterDoubleDash_opensAsAnAbsolutePath() async throws {
        try await withTempDir { directory in
            let project = directory.appendingPathComponent("-odd")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

            let (run, _) = try await run(["--", "-odd"], from: directory, in: directory)

            #expect(run.exitCode == 0)
            #expect(run.opened?.last?.hasPrefix("/") == true)
            #expect(run.opened?.last?.hasSuffix("/-odd") == true)
        }
    }

    @Test(arguments: ["missing-folder", "a-file", "--nonsense"])
    func badArgument_failsWithoutOpeningAnything(argument: String) async throws {
        try await withTempDir { directory in
            try Data().write(to: directory.appendingPathComponent("a-file"))

            let (run, _) = try await run([argument], from: directory, in: directory)

            #expect(run.exitCode == 1)
            #expect(run.opened == nil)
            #expect(run.stderr.contains("weir-link: "))
        }
    }

    @Test func help_printsUsageWithoutOpeningAnything() async throws {
        try await withTempDir { directory in
            let (run, _) = try await run(["--help"], in: directory)

            #expect(run.exitCode == 0)
            #expect(run.opened == nil)
        }
    }
}
