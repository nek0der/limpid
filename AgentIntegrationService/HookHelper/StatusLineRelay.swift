// StatusLineRelay.swift
// Weir — the `statusline` subcommand: Claude Code's status line, which keeps the plan usage and runs the person's own.

import Darwin
import Foundation

/// The status line the Claude shim gives Claude Code. Claude Code hands its
/// status line the plan's usage, and nowhere else gives it out, so we take
/// the slot, keep the usage (the Rust runtime writes it), and run the
/// person's own status line on the same input, so what they see is unchanged.
///
/// `statusline claude settings <relay command>` is the shim's half: it reads
/// the settings document the shim built on stdin and prints it back with our
/// `statusLine` in it. `statusline claude` is the status line itself.
enum StatusLineRelay {
    static let subcommand = "statusline"

    static func run(provider: String, arguments: [String]) -> Never {
        if arguments.first == "settings", arguments.count == 2 {
            exit(writeSettings(provider: provider, relayCommand: arguments[1]) ? 0 : 1)
        }
        relay(provider: provider)
    }

    /// Prints the settings document with the relay as its status line, or
    /// as it came when the person has no status line of their own: Claude
    /// Code keeps a row for a status line even when it prints nothing, so an
    /// empty slot stays empty. A failure prints nothing and exits non-zero,
    /// which the shim takes as "launch with the document as it was".
    private static func writeSettings(provider: String, relayCommand: String) -> Bool {
        do {
            let input = try readBoundedStandardInput()
            guard var settings = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
                return false
            }
            guard let statusLine = try RustStatusLineBridge.setting(
                provider: provider,
                environment: ProcessInfo.processInfo.environment,
                workingDirectory: FileManager.default.currentDirectoryPath,
                relayCommand: relayCommand
            ) else {
                FileHandle.standardOutput.write(input)
                return true
            }
            settings["statusLine"] = statusLine
            let output = try JSONSerialization.data(withJSONObject: settings, options: [.withoutEscapingSlashes])
            FileHandle.standardOutput.write(output)
            return true
        } catch {
            logHookDiagnostic("Weir status line settings: \(error)")
            return false
        }
    }

    /// Keeps the usage, then becomes the person's own status line with the
    /// input it was given. With no status line of theirs it prints nothing,
    /// which is what Claude Code shows without one.
    ///
    /// Two failures leave the line empty for this one redraw, since then we
    /// cannot run theirs as Claude Code would: an input too large to hold
    /// whole, which their command would receive cut short, and a bridge that
    /// cannot answer which command is theirs. Failing to keep the usage is
    /// not one of them (`RustStatusLineBridge.command`).
    private static func relay(provider: String) -> Never {
        let input: Data
        do {
            input = try readBoundedStandardInput()
        } catch {
            logHookDiagnostic("Weir status line: \(error)")
            exit(0)
        }
        let command: String?
        do {
            command = try RustStatusLineBridge.command(
                provider: provider,
                input: input,
                environment: ProcessInfo.processInfo.environment
            )
        } catch {
            logHookDiagnostic("Weir status line: \(error)")
            exit(0)
        }
        guard let command else { exit(0) }
        execStatusLine(command, input: input)
    }

    /// Runs `command` the way Claude Code runs a status line, under
    /// `/bin/sh -c` (what 2.1.312 runs one with, whatever the person's
    /// `SHELL`), in this process, so Claude Code's own timeout and
    /// cancellation reach it directly. We read stdin to learn the usage, so
    /// the command gets the same bytes from an unlinked temporary file in its
    /// place: all of them, since `relay` runs nothing for an input past the
    /// helper's bound.
    private static func execStatusLine(_ command: String, input: Data) -> Never {
        var template = Array((NSTemporaryDirectory() + "weir-status-line.XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            logHookDiagnostic("Weir status line: no temporary file (errno \(errno))")
            exit(0)
        }
        unlink(template)
        let isWritten = input.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                offset += written
            }
            return true
        }
        guard isWritten, lseek(descriptor, 0, SEEK_SET) == 0, dup2(descriptor, STDIN_FILENO) >= 0 else {
            logHookDiagnostic("Weir status line: could not hand the input on (errno \(errno))")
            exit(0)
        }
        close(descriptor)
        var arguments: [UnsafeMutablePointer<CChar>?] = ["sh", "-c", command].map { (argument: String) in
            strdup(argument)
        }
        arguments.append(nil)
        execv("/bin/sh", &arguments)
        logHookDiagnostic("Weir status line: could not run /bin/sh (errno \(errno))")
        exit(0)
    }
}
