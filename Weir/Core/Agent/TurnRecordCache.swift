// TurnRecordCache.swift
// Weir — hands the projection each turn record's content once, until the file changes.

import Foundation
import os

private let log = Logger.weir("agent.turn-records")

/// Which turn records the projection has already read.
///
/// The projection keeps what it read of every turn (`ProjectionState.turns`
/// on the Rust side), so a pass needs a turn's content only when its file is
/// new or has changed; every other turn goes by name alone, which keeps it.
/// A conversation can hold hundreds of turns, and reading every one on every
/// hook write would make each pass cost more the longer a person works.
///
/// A file counts as changed when its inode, modification time, or size
/// differs. The hook replaces a record by renaming a new file over it, so
/// each write is a new inode even within one clock tick.
///
/// What a pass sent is committed only once that pass succeeds: a pass that
/// fails leaves the projection's memory as it was, and the next one has to
/// send the same content again.
///
/// One pass sends at most `contentBudgetBytes` of content; what is left goes
/// to the next pass, which the adapter runs at once. The first pass after
/// launch sends every record, and with no limit on how many records there
/// are, a single one could pass the bridge's input limit and fail for good.
///
/// The budget counts content as it will be encoded, and it is checked before
/// a record is read, so a pass can go past it by one record. A record larger
/// than `maxRecordBytes` is therefore never sent: on its own it could take a
/// pass past the bridge's limit, and since a failed pass is tried again with
/// the same content, every pass after it would fail and the projection would
/// stall for good. Such a record goes by name, is logged once, and is listed
/// in `Read.oversized` on every pass; its stamp is kept as though it had been
/// sent, so it is not read again until the file changes.
@MainActor
final class TurnRecordCache {
    /// One provider's turn directory.
    struct Source: Sendable {
        let provider: String
        let directory: URL
        /// What a turn record's file name ends with; the rest is its turn id.
        let suffix: String
    }

    /// What one pass found: the files to send, and the stamps to commit once
    /// the pass succeeds.
    struct Read: Sendable {
        let files: [AgentProjectionFile]
        /// False when the budget left some content for the next pass: the
        /// projection does not know every turn yet.
        var isComplete = true
        /// Whether a record could not be read (a failed read, content that
        /// is not UTF-8), or a directory could not be listed. Its file may
        /// change without its directory changing, so the list is not trusted
        /// to stand in for the next pass's (`unchanged()`).
        var hasUnreadRecord = false
        /// The paths of the records too large to send (`maxRecordBytes`).
        /// Their turns keep what the projection read of them before, or are
        /// left out when it read nothing.
        var oversized: [String] = []
        fileprivate let stamps: [String: Stamp]
        /// Every file found, by name only: what a pass that does not look at
        /// the directories sends to keep them all.
        fileprivate let named: [AgentProjectionFile]
    }

    fileprivate struct Stamp: Equatable, Sendable {
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let size: Int64
    }

    /// By path, the stamp of the content the projection holds.
    private var sent: [String: Stamp] = [:]
    /// What the last committed read found, by name only.
    private var lastNamed: [AgentProjectionFile] = []
    /// Whether `lastNamed` matches what the projection holds; see `unchanged`.
    private var hasTrustedList = false
    /// The paths in `sent` whose stamp is that of a record held back as too
    /// large rather than of content the projection holds.
    private var lastOversized: [String] = []

    /// The content one pass sends at most, well under the bridge's 16 MB
    /// (`MAX_PROJECTION_INPUT_BYTES`): about three thousand records.
    static let contentBudgetBytes = 4 * 1024 * 1024

    /// The largest record a pass sends, as encoded. With the budget checked
    /// before each read, a pass carries at most `contentBudgetBytes` plus one
    /// record, 8 MiB, which leaves the rest of the bridge's 16 MiB for ten
    /// thousand records' names and the rest of the input. A turn record the
    /// hook writes is a few kilobytes.
    nonisolated static let maxRecordBytes = 4 * 1024 * 1024

    /// What a read away from the main actor takes with it: the stamps of
    /// the content the projection holds, as of the last commit.
    struct Snapshot: Sendable {
        fileprivate let sent: [String: Stamp]
        /// What the last commit found, by name: what a directory that
        /// cannot be listed this pass still holds, as far as we know.
        fileprivate let named: [AgentProjectionFile]
        /// The paths in `sent` held back as too large.
        fileprivate let oversized: Set<String>
    }

    func snapshot() -> Snapshot {
        Snapshot(sent: sent, named: lastNamed, oversized: Set(lastOversized))
    }

    func read(
        _ sources: [Source],
        contentBudgetBytes: Int = contentBudgetBytes,
        maxRecordBytes: Int = maxRecordBytes
    ) -> Read {
        Self.read(sources, after: snapshot(), contentBudgetBytes: contentBudgetBytes, maxRecordBytes: maxRecordBytes)
    }

    /// Lists and reads the records, on whichever thread the pass runs:
    /// listing ten thousand of them costs tens of milliseconds. The result
    /// is committed on the main actor once the pass succeeds.
    nonisolated static func read(
        _ sources: [Source],
        after snapshot: Snapshot,
        contentBudgetBytes: Int,
        maxRecordBytes: Int = maxRecordBytes
    ) -> Read {
        var pass = Gathered()
        for source in sources {
            // Joined as text: building a URL per name costs a third of a
            // pass over a thousand records.
            let base = source.directory.path + "/"
            guard let names = Self.sortedNames(atPath: source.directory.path) else {
                // Not there yet: no turns. There but not listable (no
                // permission, out of descriptors): the projection drops
                // every turn a pass does not name, so the ones the last
                // commit found go by name, which keeps them, and the next
                // pass lists the directory again.
                if FileManager.default.fileExists(atPath: source.directory.path) {
                    let kept = snapshot.named.filter { $0.provider == source.provider }
                    pass.files += kept
                    pass.named += kept
                    for (path, stamp) in snapshot.sent where path.hasPrefix(base) {
                        pass.stamps[path] = stamp
                    }
                    pass.oversized += snapshot.oversized.filter { $0.hasPrefix(base) }.sorted()
                    pass.hasUnreadRecord = true
                }
                continue
            }
            for name in names where name.hasSuffix(source.suffix) && !name.hasPrefix(".") {
                let path = base + name
                let status = Self.status(at: path)
                // Not a file the hook writes (a link, a pipe): never read, so
                // a pipe cannot stall the pass.
                if case .notRegular = status {
                    continue
                }
                let stamp: Stamp? = if case let .regular(stamp) = status {
                    stamp
                } else {
                    nil
                }
                let record = Record(
                    path: path,
                    provider: source.provider,
                    turnID: String(name.dropLast(source.suffix.count)),
                    stamp: stamp
                )
                pass.named.append(record.byName)
                Self.gather(record, into: &pass, after: snapshot, contentBudgetBytes: contentBudgetBytes, maxRecordBytes: maxRecordBytes)
            }
        }
        return Read(
            files: pass.files,
            isComplete: pass.isComplete,
            hasUnreadRecord: pass.hasUnreadRecord,
            oversized: pass.oversized,
            stamps: pass.stamps,
            named: pass.named
        )
    }

    /// What a pass gathers as it goes over the records.
    private struct Gathered {
        var files: [AgentProjectionFile] = []
        var named: [AgentProjectionFile] = []
        var stamps: [String: Stamp] = [:]
        var spent = 0
        var isComplete = true
        var hasUnreadRecord = false
        var oversized: [String] = []
    }

    /// One record a directory listed.
    private struct Record {
        let path: String
        let provider: String
        let turnID: String
        /// `nil` when the file could not be looked at (being replaced).
        let stamp: Stamp?

        var byName: AgentProjectionFile {
            AgentProjectionFile(provider: provider, name: turnID, content: nil)
        }
    }

    /// Sends `record` by name or with its content, as what the projection
    /// holds of it, the budget, and its size decide.
    private nonisolated static func gather(
        _ record: Record,
        into pass: inout Gathered,
        after snapshot: Snapshot,
        contentBudgetBytes: Int,
        maxRecordBytes: Int
    ) {
        let path = record.path
        if let stamp = record.stamp, stamp == snapshot.sent[path] {
            pass.files.append(record.byName)
            pass.stamps[path] = stamp
            if snapshot.oversized.contains(path) {
                pass.oversized.append(path)
            }
            return
        }
        // Past the budget, by name: what the projection read before
        // stands, and the file is read on the next pass.
        guard pass.spent < contentBudgetBytes else {
            pass.files.append(record.byName)
            pass.isComplete = false
            return
        }
        // Too large by its size alone: not even read.
        if let size = record.stamp?.size, size > Int64(maxRecordBytes) {
            holdBack(record, bytes: Int(size), in: &pass)
            return
        }
        // A file that cannot be read this pass goes by name, which keeps
        // what the projection read before; without a stamp it is read
        // again next pass.
        let content = FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
        let encoded = content.map(Self.encodedLength(of:)) ?? 0
        // It grew after `lstat`, or its escapes take it past the limit once
        // encoded.
        if encoded > maxRecordBytes {
            holdBack(record, bytes: encoded, in: &pass)
            return
        }
        pass.spent += encoded
        pass.files.append(AgentProjectionFile(provider: record.provider, name: record.turnID, content: content))
        if content == nil {
            pass.hasUnreadRecord = true
        } else if let stamp = record.stamp {
            pass.stamps[path] = stamp
        }
    }

    /// Sends by name a record too large to send whole, and keeps its stamp so it
    /// is not read again until it changes. Without a stamp to hold it back
    /// by, it is looked at again next pass.
    private nonisolated static func holdBack(_ record: Record, bytes: Int, in pass: inout Gathered) {
        pass.files.append(record.byName)
        if let stamp = record.stamp {
            pass.stamps[record.path] = stamp
        }
        pass.oversized.append(record.path)
        noteOversized(record.path, bytes: bytes)
    }

    /// Logged when a record is first held back, or held back again after it
    /// changed: a pass that finds the same stamp sends it by name earlier.
    private nonisolated static func noteOversized(_ path: String, bytes: Int) {
        log.error("turn record too large to send, \(bytes, privacy: .public) bytes: \(path, privacy: .private)")
    }

    /// The bytes `content` takes once `JSONEncoder` has written it as a
    /// string, quotes left out: what it adds to the bridge's input. Counted
    /// rather than encoded, since this runs over every record a pass reads.
    nonisolated static func encodedLength(of content: String) -> Int {
        var length = 0
        for byte in content.utf8 {
            switch byte {
            // `\"`, `\\`, and `\/`, which `JSONEncoder` escapes by default.
            case 0x22, 0x5C, 0x2F: length += 2
            // `\b`, `\t`, `\n`, `\f`, `\r`.
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D: length += 2
            // Every other control character as `\u00XX`.
            case 0x00..<0x20: length += 6
            default: length += 1
            }
        }
        return length
    }

    /// The last committed read again, every file by name, without looking
    /// at the directories. For a pass that a change elsewhere asked for: a
    /// turn record that changed since has already asked for a pass of its
    /// own through the directory watcher, which reads it. Nil when the last
    /// list cannot stand in for the directories (none committed yet, a pass
    /// failed after reading, or a record could not be read): the pass then
    /// reads them.
    func unchanged() -> Read? {
        guard hasTrustedList else { return nil }
        return Read(
            files: lastNamed,
            isComplete: isLastComplete,
            oversized: lastOversized,
            stamps: sent,
            named: lastNamed
        )
    }

    /// Records what `read` sent, after the pass that sent it succeeded. Files
    /// that are gone are forgotten with it.
    func commit(_ read: Read) {
        sent = read.stamps
        lastNamed = read.named
        lastOversized = read.oversized
        isLastComplete = read.isComplete
        hasTrustedList = !read.hasUnreadRecord
    }

    /// Whether the last committed read sent everything it found.
    private var isLastComplete = true

    /// Stops `unchanged()` from answering until a pass reads the directories
    /// again: one failed after reading them, so what it saw never arrived.
    func forgetLastList() {
        hasTrustedList = false
    }

    /// A directory's entries, sorted. Made native before sorting: the
    /// listing hands back bridged strings, each comparison of which goes
    /// through Foundation, and sorting ten thousand of them took a quarter
    /// of a second where native ones take a few milliseconds.
    nonisolated static func sortedNames(atPath path: String) -> [String]? {
        guard let listed = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        return listed.map { name in
            var name = name
            name.makeContiguousUTF8()
            return name
        }.sorted()
    }

    /// `lstat` rather than `FileManager.attributesOfItem`, which builds a
    /// dictionary of every attribute: over a thousand records that is most
    /// of what a pass costs (about 40 ms against 6 ms),
    /// and the sweep runs a pass every few seconds.
    private nonisolated static func status(at path: String) -> FileStatus {
        var info = stat()
        // Gone between the listing and here (being replaced): sent by name,
        // so the turn does not blink out.
        guard lstat(path, &info) == 0 else { return .unknown }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notRegular }
        return .regular(Stamp(
            inode: UInt64(info.st_ino),
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            size: info.st_size
        ))
    }

    private enum FileStatus {
        case regular(Stamp)
        case notRegular
        case unknown
    }
}
