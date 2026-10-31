// ShellCommandInstaller.swift
// Weir — puts the bundled `weir` script on the user's PATH as a symlink.

import Foundation
import OSLog

private let log = Logger.weir("shell.command")

/// What is at the place the shell command's link goes.
enum ShellCommandStatus: Equatable {
    case notInstalled
    case installed
    /// A link to the script in another copy of Weir, which may be gone by
    /// now. Replacing it loses nothing.
    case staleLink
    /// Something that isn't ours. We leave it alone, since it may be another
    /// tool of the same name.
    case occupied
}

enum ShellCommandError: WeirLocalizedError, Equatable {
    case installFailed
    case uninstallFailed

    var message: DisplayText {
        switch self {
        case .installFailed:
            .localized("The shell command couldn’t be installed.")
        case .uninstallFailed:
            .localized("The shell command couldn’t be uninstalled.")
        }
    }
}

struct ShellCommandInstaller: Sendable {
    /// Where the script sits in any copy of the app. A link ending here is
    /// ours even when it names another copy. The script's `bundled_path` and
    /// `project.yml` say the same; a test holds the script to this.
    static let bundledPath = "Contents/Resources/cli/weir"
    /// The first line of the administrator prompt, which otherwise names
    /// `osascript` and gives no reason.
    static let administratorPrompt: LocalizedStringResource =
        "Weir needs an administrator password to change its shell command."
    /// `/usr/local/bin` rather than a folder in the home directory because
    /// macOS puts it on login shells' PATH through `/etc/paths`.
    private static let installDirectory = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    /// How long the administrator prompt may stay up unanswered.
    private static let promptTimeout: Duration = .seconds(300)

    /// The script in this copy of the app, and the name its link gets. A
    /// Debug build takes a name of its own so that it never replaces the
    /// installed app's command. `nil` when the bundle lacks the script.
    static var forThisApp: Self? {
        let script = Bundle.main.bundleURL.appendingPathComponent(bundledPath, isDirectory: false)
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let name = WeirPaths.isDevBuild ? "weir-dev" : "weir"
        return Self(
            script: script,
            link: installDirectory.appendingPathComponent(name, isDirectory: false)
        )
    }

    let script: URL
    let link: URL
    /// Runs `osascript` with these arguments; a seam for the tests, which
    /// cannot answer an administrator prompt.
    var runOsascript: @Sendable ([String]) async -> ToolResult? = { arguments in
        await runTool(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: arguments,
            workingDirectory: nil,
            timeout: promptTimeout
        )
    }

    var commandName: String {
        link.lastPathComponent
    }

    /// Whether the app runs from a read-only volume: an opened disk image, or
    /// the mount Gatekeeper translocates a quarantined app to. Both go away,
    /// and a link into them with it.
    var isOnReadOnlyVolume: Bool {
        let values = try? script.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly ?? false
    }

    func status() -> ShellCommandStatus {
        let manager = FileManager.default
        // `attributesOfItem` reads the link itself, so a dangling one still
        // has attributes where `fileExists` would say nothing is there.
        guard let attributes = try? manager.attributesOfItem(atPath: link.path) else {
            return .notInstalled
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? manager.destinationOfSymbolicLink(atPath: link.path)
        else {
            return .occupied
        }
        let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
            .standardizedFileURL
        if target.resolvingSymlinksInPath().path == script.resolvingSymlinksInPath().path {
            return .installed
        }
        return target.path.hasSuffix("/" + Self.bundledPath) ? .staleLink : .occupied
    }

    /// Links the command, asking for an administrator only when the folder
    /// won't take the link without one: a Homebrew-owned `/usr/local/bin`
    /// needs no password. Returns normally when the person dismisses the
    /// prompt, which is not a failure; `status()` then says nothing changed.
    func install(prompt: String) async throws {
        let current = status()
        switch current {
        case .installed:
            return
        case .occupied:
            throw ShellCommandError.installFailed
        case .notInstalled, .staleLink:
            break
        }
        let manager = FileManager.default
        do {
            if current == .staleLink {
                try manager.removeItem(at: link)
            }
            try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: link, withDestinationURL: script)
            return
        } catch {
            log.info("linking without an administrator failed: \(error.localizedDescription, privacy: .private)")
        }
        // A new link goes without `-f`, so that a file appearing since we
        // looked makes this fail rather than be overwritten; `-f` is only for
        // replacing the link we just judged ours.
        let linkFlags = current == .staleLink ? "-sfn" : "-sn"
        try await runAsAdministrator(
            shellCommand: """
            "/bin/mkdir -p " & quoted form of item 1 of argv & " && /bin/ln \(linkFlags) " & \
            quoted form of item 2 of argv & " " & quoted form of item 3 of argv
            """,
            arguments: [link.deletingLastPathComponent().path, script.path, link.path],
            prompt: prompt,
            failure: .installFailed
        )
    }

    /// Removes the link, and only a link of ours. Returns normally when the
    /// person dismisses the prompt, as `install` does.
    func uninstall(prompt: String) async throws {
        switch status() {
        case .notInstalled:
            return
        case .occupied:
            throw ShellCommandError.uninstallFailed
        case .installed, .staleLink:
            break
        }
        do {
            try FileManager.default.removeItem(at: link)
            return
        } catch {
            log.info("unlinking without an administrator failed: \(error.localizedDescription, privacy: .private)")
        }
        try await runAsAdministrator(
            shellCommand: #""/bin/rm -f " & quoted form of item 1 of argv"#,
            arguments: [link.path],
            prompt: prompt,
            failure: .uninstallFailed
        )
    }

    /// The paths travel as arguments and reach the shell through `quoted
    /// form of`, because an app's path may hold any character and this runs
    /// as root. The prompt is the last argument.
    private func runAsAdministrator(
        shellCommand: String,
        arguments: [String],
        prompt: String,
        failure: ShellCommandError
    ) async throws {
        let script = [
            "-e", "on run argv",
            "-e", "do shell script \(shellCommand) with prompt item -1 of argv with administrator privileges",
            "-e", "end run"
        ]
        guard let result = await runOsascript(script + arguments + [prompt]) else {
            log.error("the administrator step did not finish")
            throw failure
        }
        // "(-128)" is AppleScript's "User canceled" in every language. The
        // parentheses matter: a failure's message quotes the paths, and a
        // path may hold those digits.
        if result.isSuccess || result.stderr.contains("(-128)") {
            return
        }
        log.error("the administrator step failed: \(result.stderr, privacy: .private)")
        throw failure
    }
}
