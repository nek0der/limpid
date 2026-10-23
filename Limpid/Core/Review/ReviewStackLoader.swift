// ReviewStackLoader.swift
// Limpid — reading the review tab's other files as they come near the screen, within a budget.

import Foundation

/// What the review tab's stacked diff has read of the files that are not
/// open, and the one queue that reads them. Apart from the session's open
/// diff: these are drawn and nothing more, so reading one never touches the
/// session's loading state, its banner, or the open file.
@MainActor
@Observable
final class ReviewStackLoader {
    /// A file to read, in the comparison it is read in.
    struct Request: Sendable {
        let file: ReviewFile
        let scope: ReviewScope
    }

    /// How much of the range Find searches.
    enum SearchCoverage: Equatable {
        /// Find is not asking for the whole range.
        case none
        case everyFile
        /// The range holds more than the budget: Find searches what is read.
        case loadedFilesOnly
    }

    /// What a new list does to what has been read.
    enum Retirement: Equatable {
        /// Another comparison: everything goes.
        case anotherScope
        /// The same comparison of the work tree, refreshed: the files on
        /// screen are drawn until they are read again, and the rest go, to
        /// be read when the reader comes to them. Kept, a file off screen
        /// would be neither read again nor fit to compare.
        case sameScope
        /// The same fixed range of turns, which compares two trees: nothing
        /// it read can have changed.
        case sameRange
    }

    /// A read's result, with what the file was just before the read and
    /// which read it was.
    private struct Read {
        let entry: ReviewStackEntry
        /// `nil` when it could not be taken, or the file is a submodule: the
        /// change check asks the diff's fingerprint instead.
        let state: ReviewReadState?
        let serial: Int
        /// The comparison it was read in, for that fingerprint.
        let scope: ReviewScope
    }

    /// Each file's diff, or why there is none, by file id.
    private(set) var entries: [String: ReviewStackEntry] = [:]
    /// Entries read before the list last changed, drawn until they are read
    /// again.
    private(set) var stale: Set<String> = []
    /// Bumped whenever an entry changes; the stacked rows' key follows it.
    private(set) var revision = 0
    /// The largest line number any file read in this comparison has shown,
    /// the open file's whole content included. It only grows until the
    /// comparison changes, so the gutter does not narrow and widen again as
    /// files are read, opened, and let go of.
    private(set) var highestLine = 0
    /// The files on screen and a screen either side, which are read first
    /// and never let go of for the budget.
    private(set) var window: Set<String> = []
    private(set) var searchCoverage = SearchCoverage.none

    /// How many diffs are read at once. Each is a Git process.
    @ObservationIgnored var concurrency = 4
    /// How many diff lines the stack holds before it lets go of the files
    /// farthest from the reader. Each file keeps the per-file limit
    /// (`ReviewDiffParser.maxRows`); this keeps a range of many large files
    /// from holding all of them at once.
    @ObservationIgnored var lineBudget = 250_000
    /// How long results that arrive close together wait to be published
    /// together: one rebuild of the rows for a screen of small files rather
    /// than one each. The first is published at once.
    @ObservationIgnored var publishInterval: Duration = .milliseconds(100)
    /// Whether to record what each file is before it is read, for the change
    /// check. Not for a fixed range of turns, which cannot change.
    @ObservationIgnored var tracksContent = true
    /// The session's open file, which is never let go of.
    @ObservationIgnored var openFileID: () -> String? = { nil }
    /// Called with the diffs each publish carries, so the session can check
    /// their comments and read marks against them.
    @ObservationIgnored var onPublish: ([ReviewDiff]) -> Void = { _ in }

    @ObservationIgnored private let git: any ReviewRepositoryReading
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var queue: [Request] = []
    /// What each queued file was, taken before its read. Present once taken,
    /// `nil` inside when it could not be.
    @ObservationIgnored private var queuedStates: [String: ReviewReadState?] = [:]
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var lineCounts: [String: Int] = [:]
    /// What each file read was just before its read, by file id: a staged
    /// and an unstaged diff of one path are read at different times.
    @ObservationIgnored private var states: [String: ReviewReadState?] = [:]
    @ObservationIgnored private var scopes: [String: ReviewScope] = [:]
    /// Where the next check's fingerprint round starts (`fingerprintRound`).
    @ObservationIgnored private var fingerprintCursor = 0
    /// Which read each entry came from, so an older read finishing late
    /// does not replace a newer one (the open file's own load).
    @ObservationIgnored private var serials: [String: Int] = [:]
    @ObservationIgnored private var nextSerial = 0
    /// Each listed file's place in the list, for "farthest".
    @ObservationIgnored private var order: [String: Int] = [:]
    /// Replaced with the list, so a read of the previous list's files does
    /// not land in this one's.
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Read and waiting to be published: still in flight to the queue, so
    /// a scroll does not ask Git for them again.
    @ObservationIgnored private var pending: [String: Read] = [:]
    @ObservationIgnored private var lastPublish: ContinuousClock.Instant?
    @ObservationIgnored private var flush: Task<Void, Never>?
    /// While a comment is being written, nothing is published: a new row
    /// list reloads the table under the composer, and an input method's
    /// unfinished text does not survive that.
    @ObservationIgnored private var isHeld = false
    /// The files Find asked for, read outside the window and kept like it,
    /// as far as the budget goes.
    @ObservationIgnored private var searched: Set<String> = []
    /// The current Find request's ticket (`beginSearch`).
    @ObservationIgnored private var searchTicket = 0
    /// Whether what was read was let go of (`release`): nothing is read
    /// until the review is drawn again (`resume`), so a request worked out
    /// before, and arriving after, reads nothing into a review no one
    /// draws; nor does a read of the list that ends after.
    @ObservationIgnored private(set) var isReleased = false

    /// What a file the list has no counts for is taken to hold.
    static let unknownLineEstimate = 200

    init(git: any ReviewRepositoryReading, root: URL) {
        self.git = git
        self.root = root
    }

    /// Whether a file still has to be read: never read, or read before the
    /// list changed.
    func needsDiff(_ fileID: String) -> Bool {
        entries[fileID] == nil || stale.contains(fileID)
    }

    /// The files on screen and around it, and those of them to read.
    func request(_ requests: [Request], window ids: Set<String>) {
        guard !isReleased else { return }
        if ids != window {
            window = ids
        }
        enqueue(requests.filter { ids.contains($0.file.id) })
    }

    /// Find opens (or asks again): the ticket its request carries. A request
    /// worked out after Find closed, or after a later one, holds a stale
    /// ticket and is dropped.
    func beginSearch() -> Int {
        searchTicket += 1
        return searchTicket
    }

    /// Find: every file given, as far as the budget goes, in order; only
    /// those that fit are kept from the budget. `isPartial` when files were
    /// left out before (ones too large to read at all), so the find bar
    /// does not say it searched every file.
    func requestAll(_ requests: [Request], estimates: [String: Int], ticket: Int, isPartial: Bool = false) {
        guard ticket == searchTicket, !isReleased else { return }
        searched = []
        var total = 0
        var isComplete = true
        var chosen: [Request] = []
        for request in requests {
            let id = request.file.id
            let lines = needsDiff(id) ? estimates[id] ?? Self.unknownLineEstimate : lineCounts[id] ?? 0
            guard total + lines <= lineBudget else {
                isComplete = false
                continue
            }
            total += lines
            searched.insert(id)
            if needsDiff(id) {
                chosen.append(request)
            }
        }
        searchCoverage = isComplete && !isPartial ? .everyFile : .loadedFilesOnly
        enqueue(chosen)
    }

    /// Find closed: its files are let go of again like any other, and a
    /// request still being worked out is not taken when it arrives.
    func endSearch() {
        searchTicket += 1
        searched = []
        if searchCoverage != .none {
            searchCoverage = .none
        }
    }

    /// Whether publishing waits, for a composer with an input method's
    /// unfinished text in it: a read published then reloads the table under
    /// the composer, and that text does not survive it. Only then: were it
    /// held for as long as a comment is open, the files of a review drawn again with
    /// its comment (`ParkedReview`), or read again by Refresh, would wait,
    /// loading, until the comment is saved or thrown away.
    nonisolated static func holdsPublishing(isComposingInputMethodText: Bool) -> Bool {
        isComposingInputMethodText
    }

    /// Holds publishing (`holdsPublishing`), and publishes what waited once
    /// it is let go.
    func hold(_ isHeld: Bool) {
        self.isHeld = isHeld
        if !isHeld {
            publish()
        }
    }

    /// A read the session makes of its open file: numbered with the stack's
    /// own, so whichever started later wins.
    func beginRead() -> Int {
        nextSerial += 1
        return nextSerial
    }

    /// What a file is, taken before the session reads it; `nil` when Git
    /// could not say.
    func takeState(of file: ReviewFile, scope: ReviewScope) async -> ReviewReadState? {
        await ReviewChangeCheck.take([file.path], git: git, root: root, scope: scope)[file.path]
    }

    /// Keeps the open file's diff, so it draws the same rows once another
    /// file is opened; with what the file was before it was read.
    func remember(_ diff: ReviewDiff, state: ReviewReadState?, serial: Int, scope: ReviewScope) {
        // The open file's read that ended after the release keeps nothing.
        guard !isReleased else { return }
        let id = diff.file.id
        guard (serials[id] ?? 0) <= serial else { return }
        store([id: Read(entry: .loaded(diff), state: state, serial: serial, scope: scope)])
        trim(keeping: [id])
    }

    /// The open file's whole content runs to `count` lines: the gutter is
    /// sized for them too.
    func noteLines(_ count: Int) {
        if count > highestLine {
            highestLine = count
        }
    }

    /// How many files one check asks by fingerprint, a process each: those
    /// whose state could not be taken. More take turns, one round a check.
    static let fingerprintRound = 32

    /// Whether a file read, other than the open one and those read before a
    /// refresh, is not what it was when it was read: by its state
    /// (`ReviewChangeCheck`), or, where there is none or the index cannot be
    /// read now, by its diff's fingerprint. Neither "changed" for good nor
    /// "unchanged" without asking.
    func hasChangedFiles(excluding openFileID: String?, scope: ReviewScope) async -> Bool {
        guard tracksContent else { return false }
        var watched: [(path: String, state: ReviewReadState)] = []
        var unwatched: [(diff: ReviewDiff, scope: ReviewScope)] = []
        var all: [(diff: ReviewDiff, scope: ReviewScope)] = []
        for (id, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard id != openFileID, !stale.contains(id), let diff = entry.diff else { continue }
            let fileScope = scopes[id] ?? scope
            all.append((diff, fileScope))
            if let state = states[id] ?? nil {
                watched.append((diff.file.path, state))
            } else {
                unwatched.append((diff, fileScope))
            }
        }
        switch await ReviewChangeCheck.anyChanged(watched, git: git, root: root, scope: scope) {
        case true?:
            return true
        case false?:
            return await fingerprintsChanged(unwatched)
        case nil:
            return await fingerprintsChanged(all)
        }
    }

    /// A round of `fingerprintRound` of `diffs`, starting where the last
    /// round stopped.
    private func fingerprintsChanged(_ diffs: [(diff: ReviewDiff, scope: ReviewScope)]) async -> Bool {
        guard !diffs.isEmpty else { return false }
        // Through the list a round at a time, then from its start again.
        let start = fingerprintCursor < diffs.count ? fingerprintCursor : 0
        let end = min(start + Self.fingerprintRound, diffs.count)
        fingerprintCursor = end < diffs.count ? end : 0
        for (diff, scope) in diffs[start..<end] {
            // A file Git could not fingerprint (gone, or a timeout) is
            // skipped for this round, not taken as changed; the next round
            // reads it again.
            guard let current = try? await git.fingerprint(diff.file, root: root, scope: scope) else { continue }
            if current != diff.fingerprint {
                return true
            }
        }
        return false
    }

    /// Follows a new list. Reads under way are dropped whatever the list:
    /// they read the previous one. Find asks again for the new list itself.
    func retire(_ retirement: Retirement, listed: [ReviewFile]) {
        task?.cancel()
        task = nil
        flush?.cancel()
        flush = nil
        queue = []
        queuedStates = [:]
        running = []
        pending = [:]
        lastPublish = nil
        searched = []
        generation = UUID()
        order = Dictionary(listed.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        switch retirement {
        case .anotherScope:
            entries = [:]
            stale = []
            highestLine = 0
            searchCoverage = .none
        case .sameScope:
            entries = entries.filter { window.contains($0.key) && order[$0.key] != nil }
            stale = Set(entries.keys)
        case .sameRange:
            entries = entries.filter { order[$0.key] != nil }
            stale = stale.filter { entries[$0] != nil }
        }
        lineCounts = lineCounts.filter { entries[$0.key] != nil }
        states = states.filter { entries[$0.key] != nil }
        scopes = scopes.filter { entries[$0.key] != nil }
        serials = serials.filter { entries[$0.key] != nil }
        revision += 1
    }

    /// Lets go of everything read and every read under way, Find's
    /// included, while nothing draws the review (a review tab kept for its
    /// project), and reads or keeps nothing more until the review is drawn
    /// again (`resume`).
    func release(listed: [ReviewFile]) {
        endSearch()
        retire(.anotherScope, listed: listed)
        isReleased = true
    }

    /// The review is drawn again (`ReviewSession.resumeStack`): reads are
    /// taken from now on, before its list is read again, which may fail or
    /// be overtaken. The one way out of `release`.
    func resume() {
        isReleased = false
        // The surface drawn again holds no input method's text: a hold left
        // by the one that went would keep every read from being shown.
        isHeld = false
    }

    /// Whether `id` has been read and waits to be published: held while a
    /// comment is written, or inside `publishInterval`. What a caller waits
    /// on to know a read ended, rather than a guess at how long it takes.
    func isWaitingToPublish(_ id: String) -> Bool {
        pending[id] != nil
    }

    private func isInFlight(_ id: String) -> Bool {
        running.contains(id) || pending[id] != nil
    }

    private func enqueue(_ requests: [Request]) {
        guard !isReleased else { return }
        let queued = Set(queue.map(\.file.id))
        let fresh = requests.filter { request in
            let id = request.file.id
            return needsDiff(id) && !isInFlight(id) && !queued.contains(id)
        }
        guard !fresh.isEmpty else { return }
        queue += fresh
        guard task == nil else { return }
        let generation = generation
        task = Task { [weak self] in
            await self?.drain(generation)
        }
    }

    /// The one queue: `concurrency` reads at a time, each started only while
    /// the list it was asked for is the list, and only for a file still in
    /// the window (or asked for by Find), each after its state is taken.
    private func drain(_ generation: UUID) async {
        let git = git
        let root = root
        while true {
            await withTaskGroup(of: (String, ReviewStackEntry).self) { group in
                var count = 0
                var started: [String: Int] = [:]
                var startedScopes: [String: ReviewScope] = [:]
                while true {
                    await takeQueuedStates(generation)
                    while count < concurrency, let request = next(generation) {
                        running.insert(request.file.id)
                        nextSerial += 1
                        started[request.file.id] = nextSerial
                        startedScopes[request.file.id] = request.scope
                        group.addTask {
                            let entry = await Self.read(request, git: git, root: root)
                            return (request.file.id, entry)
                        }
                        count += 1
                    }
                    guard count > 0, let (id, entry) = await group.next() else { break }
                    count -= 1
                    receive(id, entry, serial: started[id] ?? 0, scope: startedScopes[id] ?? .uncommitted, generation: generation)
                }
            }
            // Nothing suspends between this check and letting the task go,
            // so a request that comes after it starts a new one.
            guard generation == self.generation else { return }
            guard !queue.isEmpty, !Task.isCancelled else {
                task = nil
                return
            }
        }
    }

    /// Takes the state of every queued file that has none yet, in one batch
    /// per comparison: before the read, so a change racing it raises the
    /// banner once too often rather than never.
    private func takeQueuedStates(_ generation: UUID) async {
        let waiting = queue.filter { queuedStates[$0.file.id] == nil }
        guard !waiting.isEmpty else { return }
        guard tracksContent else {
            for request in waiting {
                queuedStates[request.file.id] = .some(nil)
            }
            return
        }
        let byScope = Dictionary(grouping: waiting) { $0.scope.scopeID }
        for requests in byScope.values {
            guard let scope = requests.first?.scope else { continue }
            let taken = await ReviewChangeCheck.take(Set(requests.map(\.file.path)), git: git, root: root, scope: scope)
            guard generation == self.generation else { return }
            for request in requests {
                queuedStates[request.file.id] = .some(taken[request.file.path])
            }
        }
    }

    private func next(_ generation: UUID) -> Request? {
        guard generation == self.generation, !Task.isCancelled else { return nil }
        while let index = queue.firstIndex(where: { queuedStates[$0.file.id] != nil }) {
            let request = queue.remove(at: index)
            let id = request.file.id
            guard needsDiff(id), !isInFlight(id), window.contains(id) || searched.contains(id) else {
                queuedStates.removeValue(forKey: id)
                continue
            }
            return request
        }
        return nil
    }

    private nonisolated static func read(_ request: Request, git: any ReviewRepositoryReading, root: URL) async -> ReviewStackEntry {
        do {
            var diff = try await git.diff(request.file, root: root, scope: request.scope)
            let lines = diff.lines
            let pairs = await MainActor.run { ReviewIntralineDiff.pairs(for: lines) }
            diff.intralineHighlights = await ReviewIntralineDiff.computeOffActor(pairs)
            return .loaded(diff)
        } catch {
            return .failure(error)
        }
    }

    /// The first result is published at once, and those that come within
    /// `publishInterval` of the last publish wait for the rest of it.
    private func receive(_ id: String, _ entry: ReviewStackEntry, serial: Int, scope: ReviewScope, generation: UUID) {
        guard generation == self.generation else { return }
        running.remove(id)
        let state = queuedStates.removeValue(forKey: id) ?? nil
        pending[id] = Read(entry: entry, state: state, serial: serial, scope: scope)
        let elapsed = lastPublish.map { ContinuousClock.now - $0 }
        guard let elapsed, elapsed < publishInterval else {
            publish()
            return
        }
        guard flush == nil else { return }
        let wait = publishInterval - elapsed
        flush = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            self.flush = nil
            self.publish()
        }
    }

    private func publish() {
        guard !isHeld, !pending.isEmpty else { return }
        // A read older than what the entry holds (the open file was loaded
        // since it started) is dropped.
        let published = pending.filter { id, read in (serials[id] ?? 0) <= read.serial }
        pending = [:]
        lastPublish = .now
        guard !published.isEmpty else { return }
        store(published)
        trim(keeping: Set(published.keys))
        onPublish(published.values.compactMap(\.entry.diff))
    }

    private func store(_ published: [String: Read]) {
        for (id, read) in published {
            entries[id] = read.entry
            states[id] = .some(read.state)
            scopes[id] = read.scope
            serials[id] = read.serial
            stale.remove(id)
            let lines = read.entry.diff?.lines ?? []
            lineCounts[id] = lines.count
            noteLines(lines.reduce(0) { max($0, max($1.oldLine ?? 0, $1.newLine ?? 0)) })
        }
        revision += 1
    }

    /// Lets go of the files farthest, in the list, from the window, once the
    /// stack holds more than its budget. The window, the open file, Find's
    /// files, and the files just read are never let go of: letting go of a
    /// file on screen only had it read again, and that read let go of the
    /// next one, for as long as the screen stayed there.
    private func trim(keeping kept: Set<String>) {
        var total = lineCounts.values.reduce(0, +)
        guard total > lineBudget else { return }
        var protected = window.union(searched).union(kept)
        if let open = openFileID() {
            protected.insert(open)
        }
        let anchors = (window.isEmpty ? kept : window).compactMap { order[$0] }
        let center = anchors.isEmpty ? 0 : anchors.reduce(0, +) / anchors.count
        let candidates = lineCounts.keys
            .filter { !protected.contains($0) }
            .sorted { abs((order[$0] ?? 0) - center) > abs((order[$1] ?? 0) - center) }
        var hasEvictedEntries = false
        for id in candidates where total > lineBudget {
            total -= lineCounts[id] ?? 0
            entries.removeValue(forKey: id)
            lineCounts.removeValue(forKey: id)
            states.removeValue(forKey: id)
            scopes.removeValue(forKey: id)
            serials.removeValue(forKey: id)
            stale.remove(id)
            hasEvictedEntries = true
        }
        if hasEvictedEntries {
            revision += 1
        }
    }
}
