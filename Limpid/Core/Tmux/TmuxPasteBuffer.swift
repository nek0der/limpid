// TmuxPasteBuffer.swift
// Limpid — a clipboard paste into a mirror pane as a tmux buffer: the size cap, the confirmation rule, the file tmux loads.

import Darwin
import Foundation
import OSLog

private let log = Logger.limpid("tmux.paste")

/// A paste into a mirror pane goes to tmux as a buffer, not as keystrokes:
/// `paste-buffer -p` brackets it exactly when the program in the pane has
/// bracketed paste on, which only tmux knows. The text reaches tmux through
/// a file because a control-mode command is one line and `load-buffer`
/// cannot read our stdin, which is the control channel.
enum TmuxPasteBuffer {
    /// Larger pastes are refused. tmux holds the whole buffer in memory and
    /// writes it to the pane in one go; 8 MiB is far beyond anything typed
    /// into a terminal on purpose.
    static let byteLimit = 8 * 1024 * 1024

    /// Whether the paste needs the user's confirmation before it is sent.
    ///
    /// Stricter than an ordinary pane, which trusts a bracketed paste: we
    /// cannot tell whether this pane has bracketed paste on. Our copy of
    /// its modes can miss a `?2004l` sent while the pane was paused, and
    /// without the brackets tmux turns every newline into Enter.
    static func needsConfirmation(_ text: String) -> Bool {
        text.contains { $0.isNewline } || text.contains("\u{1B}[201~")
    }

    /// A buffer name no other client uses, so two pastes never overwrite
    /// each other and `-d` deletes only ours.
    static func bufferName(id: UUID = UUID()) -> String {
        "limpid-\(id.uuidString.lowercased())"
    }

    /// Where the files live: a per-user directory only we can list.
    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dev.limpid.tmux-paste", isDirectory: true)
    }

    /// Drop whatever an earlier run left in the paste directory, at launch.
    /// A file is removed as soon as tmux has read it or refused to, but a
    /// crash in between leaves the clipboard's text on disk, and nothing
    /// running now can be waiting for a file from a run that is over. The
    /// directory is created first, so a launch that never pastes still
    /// leaves it owner-only for the first paste that does.
    static func removeLeftoverFiles(in directory: URL = defaultDirectory) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("limpid-") {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                log.error("left a paste file behind: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Write `text` to a new file readable by us alone. Created with
    /// `O_EXCL` and mode 0600 in one step, so no other process can open it
    /// between creation and the permission change.
    static func writeFile(_ text: String, in directory: URL, name: String) throws -> URL {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        let url = directory.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else {
                let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                try? FileManager.default.removeItem(at: url)
                throw failure
            }
            offset += written
        }
        return url
    }

    /// `load-buffer` reads the file; `paste-buffer -d` deletes the buffer
    /// once it is in the pane. tmux runs them in order, and the second
    /// fails with "no buffer" if the first did.
    static func commands(bufferName: String, file: URL, pane: String) -> (load: String, paste: String) {
        let buffer = TmuxProtocol.quote(bufferName)
        return (
            "load-buffer -b \(buffer) \(TmuxProtocol.quote(file.path))",
            "paste-buffer -p -d -b \(buffer) -t \(TmuxProtocol.quote(pane))"
        )
    }

    static func deleteCommand(bufferName: String) -> String {
        "delete-buffer -b \(TmuxProtocol.quote(bufferName))"
    }
}
