// IgnoredFileCopier.swift
// Weir — copies the files Git ignores that a project names into a new worktree, off the main actor.

import Foundation
import os
import WeirDomain

/// Copies the paths `IgnoredFileSelection` picked from the project's folder
/// into a worktree just made. The copy runs on a queue of its own, so
/// a large folder (`node_modules`) never holds the main actor, and it is
/// careful in four ways:
/// - it never writes over anything: a path the worktree already has is left,
///   since Git checked it out or the person put it there;
/// - a symbolic link is copied as the link, not what it points at, and a
///   path whose folders lead out of either folder through a link is not
///   copied, nor is a folder made for it: nothing outside the project is
///   read or written;
/// - a path that would take the copies past `byteLimit` is left out, and
///   the smaller ones after it still go: a pattern that names a build
///   folder by mistake must not fill the disk, nor keep `.env` out;
/// - it stops between paths once its task is canceled (the worktree is
///   being deleted, or hidden), and copies nothing into a worktree that
///   is gone.
enum IgnoredFileCopier {
    /// What a copy did, path by path, relative to the project's folder.
    struct Report: Equatable, Sendable {
        var copied: [String] = []
        /// The worktree had the path already.
        var kept: [String] = []
        var failed: [String] = []
        /// Left out: they would have taken the copies past the limit.
        var overLimit: [String] = []
        /// The task was canceled before every path was copied.
        var isCanceled = false
        /// The worktree was gone before every path was copied: deleted
        /// meanwhile.
        var isDestinationGone = false
    }

    /// 256 MiB: more than any `.env` or key, less than a dependency folder
    /// a pattern should not have named.
    static let byteLimit: Int64 = 256 * 1024 * 1024

    /// Copies `paths` from `source` into `destination`, on a background
    /// queue. A path the project's folder no longer has is passed over: a
    /// pattern can name a file not made yet.
    static func copy(
        _ paths: [String],
        from source: URL,
        to destination: URL,
        byteLimit: Int64 = byteLimit
    ) async -> Report {
        let canceled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let report = copySync(paths, from: source, to: destination, byteLimit: byteLimit) {
                        canceled.withLock { $0 }
                    }
                    continuation.resume(returning: report)
                }
            }
        } onCancel: {
            canceled.withLock { $0 = true }
        }
    }

    private static func copySync(
        _ paths: [String],
        from source: URL,
        to destination: URL,
        byteLimit: Int64,
        isCanceled: () -> Bool
    ) -> Report {
        #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let fileManager = FileManager.default
        let sourceRoot = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationRoot = destination.standardizedFileURL.resolvingSymlinksInPath()
        var report = Report()
        var total: Int64 = 0
        for path in paths {
            // A worktree deleted meanwhile is not made again by the copy.
            guard exists(destinationRoot) else {
                report.isDestinationGone = true
                break
            }
            guard !isCanceled() else {
                report.isCanceled = true
                break
            }
            let from = sourceRoot.appendingPathComponent(path)
            let to = destinationRoot.appendingPathComponent(path)
            guard isInside(from.deletingLastPathComponent(), sourceRoot) else {
                report.failed.append(path)
                continue
            }
            guard exists(from) else { continue }
            if exists(to) {
                report.kept.append(path)
                continue
            }
            let parent = to.deletingLastPathComponent()
            // Checked before any folder is made: one the checkout made can
            // be a link out of the worktree, and a folder made through it
            // would be outside.
            guard isInside(nearestExisting(parent), destinationRoot) else {
                report.failed.append(path)
                continue
            }
            let size = Self.size(of: from)
            guard total + size <= byteLimit else {
                report.overLimit.append(path)
                continue
            }
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                try fileManager.copyItem(at: from, to: to)
                total += size
                report.copied.append(path)
            } catch {
                report.failed.append(path)
            }
        }
        return report
    }

    /// `url`, or the nearest folder above it that exists.
    private static func nearestExisting(_ url: URL) -> URL {
        var current = url
        while !exists(current), current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
        }
        return current
    }

    /// Whether `url`, its links resolved, is `root` or inside it.
    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        RepositoryPath.contains(root.path, url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    /// Whether something is at `url`, a link that points nowhere included.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// The bytes of the regular files at or under `url`, links not followed.
    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true {
            return 0
        }
        if values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard values.isDirectory == true,
              let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walk {
            if let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
