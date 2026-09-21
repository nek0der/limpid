// TmuxWindowMirror+Verbs.swift
// Limpid — the pane operations a mirror tab translates into tmux commands.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.mirror")

/// Every verb has the same shape: send the command, then wait for the
/// `%layout-change` tmux answers with and draw that (design §10). The tree
/// is never edited here; a failure comes back as `%error`, is reported,
/// and leaves the picture as it was.
///
/// Each verb names its own localized failure message. tmux's `%error`
/// text is terse, version-dependent English that does not say which
/// operation it refers to, so it goes to the log only.
///
/// Nothing is sent while the mirror is disconnected (`canSend`). The
/// caller that looked the mirror up tells the user; a verb that arrives
/// here anyway came by a delayed route and is dropped.
extension TmuxWindowMirror {
    /// `split-window` next to `paneID`. `-c` is left off on purpose so
    /// tmux's own default for the new pane's directory applies.
    func split(paneID: UUID, direction: SplitDirection) {
        guard let pane = tmuxPane(for: paneID) else { return }
        let flag = direction == .horizontal ? "-h" : "-v"
        run("split-window \(flag) -t \(TmuxProtocol.quote(pane))", failure: String(localized: "Couldn't split the pane"))
    }

    /// `swap-pane`: the two panes trade places, the layout keeps its shape.
    func swap(_ first: UUID, _ second: UUID) {
        guard let source = tmuxPane(for: first), let target = tmuxPane(for: second) else { return }
        run(
            "swap-pane -s \(TmuxProtocol.quote(source)) -t \(TmuxProtocol.quote(target))",
            failure: String(localized: "Couldn't swap the panes")
        )
    }

    /// `select-layout -E` spreads the pane and its neighbors evenly. The
    /// named layouts (`even-horizontal`, ...) are not used: they flatten
    /// the nesting, so `main-vertical` would come back as a single row.
    func equalize(from paneID: UUID) {
        guard let pane = tmuxPane(for: paneID) else { return }
        run("select-layout -E -t \(TmuxProtocol.quote(pane))", failure: String(localized: "Couldn't equalize the splits"))
    }

    /// `resize-pane -Z`. Zoom state is read back from the window flags on
    /// `%layout-change`, never set locally: a local zoom would draw one
    /// pane over the whole area while tmux still thinks it is small.
    func toggleZoom(paneID: UUID) {
        guard let pane = tmuxPane(for: paneID) else { return }
        run("resize-pane -Z -t \(TmuxProtocol.quote(pane))", failure: String(localized: "Couldn't toggle the pane zoom"))
    }

    /// `resize-pane -x` / `-y` with an absolute size, for a divider drag.
    /// Absolute rather than incremental, so a request sent before the
    /// previous one was answered cannot apply twice. At most one request
    /// is outstanding; a newer one replaces whatever was waiting, so a
    /// drag of hundreds of events sends only as many as tmux can answer.
    func resize(paneID: UUID, direction: SplitDirection, cells: Int) {
        guard cells > 0 else { return }
        queuedResize = PendingResize(paneID: paneID, direction: direction, cells: cells)
        sendQueuedResize()
    }

    /// The window `break-pane` made: its id, and the name tmux gave it.
    struct BrokenOutWindow: Equatable {
        let windowID: String
        let windowName: String
    }

    /// `break-pane` moves the pane into a new window of its session and
    /// reports that window's id and name, so the caller can open a mirror
    /// for it under the name tmux shows. The id holds no space; the name
    /// may.
    func breakPane(paneID: UUID, completion: @escaping (BrokenOutWindow?) -> Void) {
        guard canSend, let pane = tmuxPane(for: paneID) else {
            completion(nil)
            return
        }
        connection.send("break-pane -d -s \(TmuxProtocol.quote(pane)) -P -F '#{window_id} #{window_name}'") { [weak self] lines, isError in
            if isError {
                self?.reportFailure(lines, message: String(localized: "Couldn't move the pane to a new tab"))
                completion(nil)
            } else {
                completion(lines.first.flatMap(TmuxProtocol.splitFirstField).map {
                    BrokenOutWindow(windowID: $0.0, windowName: $0.1)
                })
            }
        }
    }

    /// The window `new-window` made: its id, the pane tmux started in it,
    /// and the name it was given.
    struct CreatedWindow: Equatable {
        let windowID: String
        let paneID: String
        let windowName: String
    }

    /// `new-window` in this mirror's session, placed right after the window
    /// the tab shows, and reported so the caller can open a mirror tab on
    /// it. `-d` keeps every client attached to the session where it is:
    /// the window belongs to the tab about to be opened for it, not to
    /// whatever else shows this session.
    ///
    /// The name comes last because it may hold spaces; the two ids may not.
    func newWindow(completion: @escaping (CreatedWindow?) -> Void) {
        guard canSend else {
            completion(nil)
            return
        }
        let command = "new-window -d -a -t \(TmuxProtocol.quote(windowID)) -P -F '#{window_id} #{pane_id} #{window_name}'"
        connection.send(command) { [weak self] lines, isError in
            guard !isError else {
                self?.reportFailure(lines, message: String(localized: "Couldn't open a new tmux window"))
                completion(nil)
                return
            }
            completion(lines.first.flatMap(Self.parseCreatedWindow))
        }
    }

    static func parseCreatedWindow(_ line: String) -> CreatedWindow? {
        guard let (windowID, rest) = TmuxProtocol.splitFirstField(line),
              let (paneID, name) = TmuxProtocol.splitFirstField(rest),
              windowID.hasPrefix("@"), paneID.hasPrefix("%")
        else { return nil }
        return CreatedWindow(windowID: windowID, paneID: paneID, windowName: name)
    }

    /// `kill-window`: everything running in the window ends, for every
    /// client showing it. The one thing Limpid offers that destroys work in
    /// tmux, so nothing calls it without a confirmation (design D4). What
    /// becomes of the tab is left to the `%window-close` tmux sends back,
    /// which is the same route as a window killed from anywhere else.
    func killWindow() {
        run("kill-window -t \(TmuxProtocol.quote(windowID))", failure: String(localized: "Couldn't quit the tmux window"))
    }

    /// `join-pane` moves a pane of this window into `window` of the same
    /// session, split against that window's active pane.
    func joinPane(paneID: UUID, into window: String) {
        guard let pane = tmuxPane(for: paneID) else { return }
        run(
            "join-pane -s \(TmuxProtocol.quote(pane)) -t \(TmuxProtocol.quote(window))",
            failure: String(localized: "Couldn't move the pane to that tab")
        )
    }

    /// Paste `text` into the pane as a tmux buffer (`TmuxPasteBuffer`).
    /// The file is removed as soon as tmux has read it, or when the
    /// command fails, which includes the connection ending first. A failed
    /// paste deletes the buffer, since `-d` only deletes it on success;
    /// when the load failed too there is no buffer, and tmux's refusal of
    /// the delete is not read.
    func paste(_ text: String, paneID: UUID, directory: URL = TmuxPasteBuffer.defaultDirectory) {
        guard canSend, let pane = tmuxPane(for: paneID) else { return }
        let failure = String(localized: "Couldn't paste into the pane")
        let bufferName = TmuxPasteBuffer.bufferName()
        let file: URL
        do {
            file = try TmuxPasteBuffer.writeFile(text, in: directory, name: bufferName)
        } catch {
            log.error("paste file not written: \(String(describing: error), privacy: .public)")
            onCommandFailed?(failure)
            return
        }
        let commands = TmuxPasteBuffer.commands(bufferName: bufferName, file: file, pane: pane)
        connection.send(commands.load) { lines, isError in
            // Already read, or never going to be: the file has no further use.
            try? FileManager.default.removeItem(at: file)
            if isError {
                log.error("load-buffer refused: \(lines.joined(separator: " "), privacy: .private)")
            }
        }
        connection.send(commands.paste) { [weak self] lines, isError in
            guard isError, let self else { return }
            connection.send(TmuxPasteBuffer.deleteCommand(bufferName: bufferName))
            reportFailure(lines, message: failure)
        }
    }

    // MARK: - Plumbing

    private func run(_ command: String, failure: String) {
        guard canSend else { return }
        // The tmux command name says which verb ran; its arguments name
        // panes and windows of the user's session.
        let name = command.prefix { $0 != " " }
        let arguments = command.dropFirst(name.count)
        log.debug("verb \(String(name), privacy: .public)\(String(arguments), privacy: .private)")
        connection.send(command) { [weak self] lines, isError in
            if isError {
                self?.reportFailure(lines, message: failure)
            }
        }
    }

    func sendQueuedResize() {
        guard canSend, !isResizeInFlight, let next = queuedResize, let pane = tmuxPane(for: next.paneID) else { return }
        queuedResize = nil
        isResizeInFlight = true
        let flag = next.direction == .horizontal ? "-x" : "-y"
        connection.send("resize-pane -t \(TmuxProtocol.quote(pane)) \(flag) \(next.cells)") { [weak self] lines, isError in
            guard let self else { return }
            self.isResizeInFlight = false
            if isError {
                self.reportFailure(lines, message: String(localized: "Couldn't resize the pane"))
            }
            self.sendQueuedResize()
        }
    }

    /// `message` is what the user reads. `lines` is tmux's own reply, which
    /// can quote session names, window names or paths, so it is logged
    /// as private.
    ///
    /// A connection that ends fails every command still waiting, with the
    /// same error flag as a `%error`. Those failures arrive after the store
    /// marked this mirror disconnected, and they are not tmux refusing the
    /// verb, so the user is not told the verb failed.
    ///
    /// Only the toast is raised here. Every `%error` tmux sends is already
    /// recorded once, with the command it refused, by the transport that
    /// paired it (`TmuxControlTransport.handle`); a second error line for
    /// the same refusal only makes the log harder to read.
    private func reportFailure(_ lines: [String], message: String) {
        guard connectionState == .connected else {
            log.debug("verb ended with the connection: \(lines.joined(separator: " "), privacy: .private)")
            return
        }
        onCommandFailed?(message)
    }
}
