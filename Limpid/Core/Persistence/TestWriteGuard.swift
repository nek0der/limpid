// TestWriteGuard.swift
// Limpid — refuses a file change a test run aims at the user's real data.

import Darwin
import Foundation
import OSLog

private let log = Logger.limpid("fs.guard")

/// The rule every change to Limpid's own files passes through
/// (`SecureFileWrite`) while the test host runs: nothing under the user's real
/// `~/Library`, or the `~/.codex` Limpid installs hooks into, is touched. Real
/// user data was corrupted once by a test that forgot to inject its directory,
/// and redirecting the default directory alone does not stop a test that
/// builds a path of its own.
///
/// We refuse rather than trap. A trap ends the whole test host, so every other
/// test's result is lost, and the test that proves the refusal could not run
/// in the same process. A refusal leaves the bytes untouched, throws where the
/// caller can throw, and logs a fault (`dev.limpid` / `fs.guard`) that a run
/// can be searched for.
enum TestWriteGuard {
    /// Thrown in place of a change the guard refused. It reaches a person only
    /// as a test failure or a log line, so it is not localized.
    struct Refusal: Error, CustomStringConvertible {
        let path: String

        var description: String {
            "refused a change under the user's real data during a test run: \(path)"
        }
    }

    /// Throws `Refusal` when this process is the test host and `url` resolves
    /// under a protected folder. Outside the test host it costs the test-host
    /// check (a stored flag and two class lookups) and never touches the file
    /// system.
    static func check(_ url: URL) throws {
        guard LimpidPaths.isRunningInTests else { return }
        guard let folder = protectedFolder(containing: url) else { return }
        // The path names the user's home, so it stays private; the folder's
        // kind is ours and is what tells a reader which rule fired.
        log.fault(
            "refused a test-run change under \(folder.rawValue, privacy: .public) at \(url.path, privacy: .private)"
        )
        throw Refusal(path: url.path)
    }

    /// The kinds of folder the guard protects, as the fault names them.
    enum ProtectedFolder: String, Sendable {
        case library
        case codexHome
    }

    /// Which protected folder a change at `url` could touch, or `nil` when it
    /// touches none.
    static func protectedFolder(containing url: URL) -> ProtectedFolder? {
        firstRoot(touchedBy: url, among: protectedFolders.map(\.root)).map { protectedFolders[$0].folder }
    }

    /// The non-throwing form for the helpers that log and carry on: `true`
    /// when the change may go ahead.
    static func permits(_ url: URL) -> Bool {
        do {
            try check(url)
            return true
        } catch {
            return false
        }
    }

    /// Whether a change at `url` could touch anything inside `protectedRoots`.
    /// Which reading of a path a change follows depends on the operation: a
    /// rename or an unlink acts on the last name itself, an open that follows
    /// links acts on its target, and the tmp file `writeAtomic` makes sits in
    /// the folder as written. We cannot tell which a caller will do, so the
    /// change is refused when any reading lands inside a root, as written or
    /// resolved: a link inside `~/.codex` pointing at a dotfiles folder is
    /// still a change inside `~/.codex`. Components are compared without case
    /// because the default APFS volume ignores it.
    static func refuses(_ url: URL, protectedRoots: [URL]) -> Bool {
        firstRoot(touchedBy: url, among: protectedRoots) != nil
    }

    /// The index of the first of `roots` a change at `url` could touch. The
    /// change's landings are worked out once, since each asks the file system.
    private static func firstRoot(touchedBy url: URL, among roots: [URL]) -> Int? {
        let targets = landings(of: url.path).map(folded)
        return roots.firstIndex { root in
            let prefixes = [lexicalPath(root.path), resolvedPath(root.path)].map(folded)
            return targets.contains { target in
                prefixes.contains { prefix in
                    target.count >= prefix.count && Array(target.prefix(prefix.count)) == prefix
                }
            }
        }
    }

    /// The three places a change at `path` can act on: the path as written
    /// (with `.` and `..` folded as text), its folder resolved with the last
    /// name kept as is, and the path fully resolved.
    private static func landings(of path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        var landings = [lexicalPath(path), resolvedPath(path)]
        if ![".", "..", "/"].contains(name) {
            let folder = resolvedPath((path as NSString).deletingLastPathComponent)
            landings.append((folder as NSString).appendingPathComponent(name))
        }
        return landings
    }

    private static func lexicalPath(_ path: String) -> String {
        joined("/", (path as NSString).pathComponents)
    }

    /// The real user's `~/Library` and `~/.codex`. The home comes from the
    /// password database as well as `NSHomeDirectory()`, so a test that
    /// points `HOME` somewhere else cannot move the folders this protects.
    static var protectedRoots: [URL] {
        protectedFolders.map(\.root)
    }

    /// `protectedRoots`, each with the kind of folder it is.
    private static let protectedFolders: [(folder: ProtectedFolder, root: URL)] = {
        var homes = [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)]
        if let home = passwordDatabaseHome() {
            homes.append(URL(fileURLWithPath: home, isDirectory: true))
        }
        return homes.flatMap { home in
            [
                (.library, home.appendingPathComponent("Library", isDirectory: true)),
                (.codexHome, home.appendingPathComponent(".codex", isDirectory: true))
            ]
        }
    }()

    /// `path` with every link followed, as an open that follows links would
    /// see it. The deepest part that exists goes through `realpath(3)`, so a
    /// link and a `..` after it are followed the way the kernel follows them;
    /// the part that does not exist yet is put back as written. Existence is
    /// asked with `lstat`, so a link whose target is missing is followed to
    /// that target, where such an open would create the file.
    static func resolvedPath(_ path: String) -> String {
        resolvedPath(path, depth: 0)
    }

    private static func resolvedPath(_ path: String, depth: Int) -> String {
        var components = (path as NSString).pathComponents
        var missing: [String] = []
        while components.count > 1 {
            let prefix = NSString.path(withComponents: components)
            var info = stat()
            if lstat(prefix, &info) == 0 {
                if let real = realpath(prefix, nil) {
                    defer { free(real) }
                    return joined(String(cString: real), missing)
                }
                guard info.st_mode & S_IFMT == S_IFLNK, depth < maximumLinkDepth,
                      let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix)
                else { break }
                let target = destination.hasPrefix("/")
                    ? destination
                    : ((prefix as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
                return resolvedPath(joined(target, missing), depth: depth + 1)
            }
            missing.insert(components.removeLast(), at: 0)
        }
        return joined(NSString.path(withComponents: components), missing)
    }

    /// The kernel's own bound on links followed in one path (`MAXSYMLINKS`),
    /// so a loop of dangling links cannot recurse forever.
    private static let maximumLinkDepth = 32

    /// The Data volume's firmlinks name the same folder twice
    /// (`/System/Volumes/Data/Users/...` is `/Users/...`), and `realpath`
    /// keeps whichever was written, so the longer form is folded away.
    private static let dataVolumePrefix = "/System/Volumes/Data/"

    /// `getpwuid_r` rather than `getpwuid`, whose static buffer another
    /// thread may be reading while this initializer runs.
    private static func passwordDatabaseHome() -> String? {
        var entry = passwd()
        var found: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        return buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard let base = storage.baseAddress,
                  getpwuid_r(getuid(), &entry, base, storage.count, &found) == 0,
                  found != nil, let directory = entry.pw_dir
            else { return nil }
            return String(cString: directory)
        }
    }

    /// Puts the missing part back, folding its `.` and `..` by hand. Nothing
    /// in it exists, so there is no link for the kernel to follow first, and
    /// `standardizingPath` would drop `/private` only from a path that exists,
    /// which would set a missing target apart from the existing root.
    private static func joined(_ base: String, _ missing: [String]) -> String {
        var components = (base as NSString).pathComponents
        for component in missing {
            switch component {
            case ".", "/":
                continue
            case "..":
                if components.count > 1 {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }
        var path = NSString.path(withComponents: components)
        if path.hasPrefix(dataVolumePrefix) {
            path = "/" + path.dropFirst(dataVolumePrefix.count)
        }
        return path
    }

    private static func folded(_ path: String) -> [String] {
        (path as NSString).pathComponents.map { $0.lowercased() }
    }
}
