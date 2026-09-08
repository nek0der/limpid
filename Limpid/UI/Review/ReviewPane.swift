// ReviewPane.swift
// Limpid — the review surface, docked above the terminal it writes back to.

import AppKit
import SwiftUI

struct ReviewPane: View {
    let directory: URL
    /// How wide the surface is. Handed down from the pane area rather than
    /// measured here: a geometry reader in this body would rebuild the diff
    /// table on every frame of a divider drag.
    let available: CGFloat
    let onClose: () -> Void
    var draftDirectory: URL?
    var onInserted: ((UUID) -> Void)?

    @Environment(\.reviewStores) private var reviewStores
    @State private var store: ReviewStore?
    @State private var failure: String?
    /// Bumped by Try Again. The open is keyed on it as well as on the
    /// directory, so asking again re-runs it without the reader having to
    /// close review and come back.
    @State private var reloadToken = 0
    /// Whether the open has taken long enough to be worth saying so.
    @State private var isSlowToOpen = false

    var body: some View {
        Group {
            if let store {
                ReviewWorkspaceView(
                    store: store,
                    available: available,
                    onClose: onClose,
                    onInserted: onInserted
                )
                // Retargeting to another worktree keeps this view's identity,
                // which would otherwise carry the previous root's selection
                // and composer into a diff they do not belong to.
                .id(store.root)
            } else {
                loadingView
            }
        }
        .task(id: [directory.path, String(reloadToken)]) { await loadStore() }
    }

    /// What stands in until the repository is resolved.
    ///
    /// Deliberately empty for the first quarter second. Resolving the root is
    /// one `rev-parse`, so on a repository that is already warm the spinner
    /// appeared and left inside a frame or two — a flash the reader reads as
    /// the surface failing to open rather than as it opening. It is the wait
    /// that needs explaining, not the open.
    private var loadingView: some View {
        VStack(spacing: 16) {
            if let failure {
                Text(verbatim: failure)
                HStack(spacing: 12) {
                    // The messages that land here name a retry — "Refresh to
                    // try again" — and this screen had nothing but Close on it.
                    Button("Try Again") { reloadToken += 1 }
                        .accessibilityLabel(Text("Try Again"))
                    closeButton
                }
            } else if isSlowToOpen {
                ProgressView("Loading changes…")
                closeButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The surface's own background, so what the reader sees is the panel
        // arriving rather than a hole where the terminal used to be.
        .background(LimpidColor.terminalColumnBackground)
        .task(id: directory) {
            isSlowToOpen = false
            try? await Task.sleep(for: .milliseconds(250))
            isSlowToOpen = !Task.isCancelled
        }
    }

    private var closeButton: some View {
        Button("Close", action: onClose)
            .accessibilityLabel(Text("Close"))
    }

    private func loadStore() async {
        failure = nil
        do {
            let root = try await ReviewGit.root(at: directory)
            try Task.checkCancellation()
            // Nothing to do when this task ran again for the repository
            // already on screen. It used to clear the store first, which drops
            // the last strong reference to a pooled one — the pool holds them
            // weakly — so the store came back as a new instance and took the
            // scope, the open file and what had been marked stale with it.
            // The previous target's surface still goes away before another
            // repository's arrives, which is what that clearing was for: left
            // up, its diff and its Insert button belonged to a worktree the
            // reader had already navigated away from.
            guard store?.root != root else { return }
            if let draftDirectory {
                store = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: draftDirectory))
            } else {
                store = reviewStores.store(root: root)
            }
        } catch is CancellationError {
            // A newer directory took over; that task owns the screen now.
        } catch {
            // The surface belongs to a repository we could not resolve.
            // Leaving the previous one up left its diff and its Insert button
            // pointed at a worktree the reader had navigated away from — and
            // the message below is drawn where the store is not, so without
            // this it was never shown at all.
            store = nil
            failure = error.localizedDescription
        }
    }
}

/// A comment the reader asked to be taken to, held while its file loads.
struct ReviewJump: Equatable {
    let fileID: String
    let start: Int
    let end: Int
    /// The column the comment was written in, so landing on it in the split
    /// layout selects the run the reader will recognize.
    var side: ReviewSide?
}

struct ReviewWorkspaceView: View {
    let store: ReviewStore
    /// Whether a read has been running long enough to be worth saying so.
    ///
    /// Separate from `isSlowToOpen`, which covers the surface arriving. This
    /// one covers a file arriving inside it: opening a large diff runs Git,
    /// the parser and the highlighter, and until they answer the row the
    /// reader clicked stays shut, which reads as a click that missed.
    @State private var isSlowToLoad = false
    /// See `ReviewPane.available`.
    let available: CGFloat
    let onClose: () -> Void
    var onInserted: ((UUID) -> Void)?

    @Environment(WindowSession.self) var session
    @Environment(ReviewPresentation.self) var reviewPresentation
    @Environment(\.surfaceRegistry) var registry
    @Environment(ToastCenter.self) var toastCenter
    @Environment(SettingsStore.self) var settingsStore
    @State var fileID: String?
    @State var selection = ReviewSelection()
    /// Editing reuses the composer rather than opening a modal on top of a
    /// surface that already covers the window, so which comment is being
    /// rewritten has to travel with it.
    @State var composer = ReviewComposerState()
    /// Polled rather than computed: resolving what is in front of the pane's
    /// terminal blocks on a `sysctl` and, under tmux hosting, on tmux itself.
    @State var destination: ReviewDestination?
    @State var isInserting = false
    @State var isShowingPrompt = false
    /// Incremented every time the reader asks for the find bar. See
    /// `ReviewFindField.focusRequest`.
    @State var findFocusRequest = 0
    /// The query the hits were counted for. The scan walks every row of the
    /// file, so it follows the field rather than leading it: typing a word into
    /// a hundred-thousand-line diff scanned it once per letter.
    @State var scannedQuery = ""
    /// True until the first probe for the current pane answers. Without it the
    /// chip claims there is no terminal while it is still looking.
    @State var isResolvingDestination = true
    /// Not observable state: a place to keep the last row list so the body can
    /// read it without rebuilding it. See `rows`.
    @State var rowCache = ReviewRowCache()
    /// Same idea as `rowCache`: a plain box, so telling probes apart does not
    /// cost a view invalidation every two seconds.
    @State var destinationProbe = ReviewProbeToken()
    /// Where to put the selection once the file a comment lives in has loaded.
    @State var pendingJump: ReviewJump?
    @State var isTreeLayout = false
    @State var hidesViewedFiles = false
    @State var search = ReviewSearch()
    /// One number column, sized to the file being read. Stored rather than
    /// computed: the scan is over every line of the diff, and a computed
    /// property would repeat it on every keystroke in the composer.
    @State var numberWidth = ReviewRowMetrics.defaultNumberWidth

    /// The comments that still stand. Resolved ones stay in the draft as the
    /// record of what was asked, and leave everything that acts on a comment:
    /// the diff, the counts, and the prompt.
    private var openComments: [ReviewComment] {
        store.comments.filter { !$0.isResolved }
    }

    /// The files the reader is being shown, which is what `n` and `p` walk.
    ///
    /// The open one stays whatever its mark says: a list that denied the file
    /// on screen was there would be answering a different question from the
    /// diff beside it. The rail narrows this further by its own text filter,
    /// which is a search rather than a scope and does not belong here.
    private var listedFiles: [ReviewFile] {
        // In the order the rail draws them, which is what `n` and `p` walk.
        ReviewFileTree.listed(
            ReviewFileTree.ordered(store.files, isTree: isTreeLayout),
            hidingViewed: hidesViewedFiles,
            viewed: Set(store.viewed.keys),
            open: fileID
        )
    }

    /// The largest line number the gutter may ever have to draw for this file.
    ///
    /// The whole file rather than the patch: unfolding reveals numbers the
    /// diff never showed, and a gutter that grew a digit part-way through
    /// would shift every line of the diff sideways as the reader read it.
    /// The store publishes the file's content and its diff together so that
    /// this is answerable the first time it is asked.
    private var highestLine: Int {
        let patch = store.diff?.lines.reduce(0) { highest, line in
            max(highest, max(line.oldLine ?? 0, line.newLine ?? 0))
        } ?? 0
        return max(patch, store.source.count)
    }

    /// How many comments the banner is about. A resolved comment can also be
    /// stale — resolving is what the banner's own bulk action does to them —
    /// and counting those would leave it standing with nothing left to act on.
    private var staleOpenComments: Int {
        openComments.count { store.staleCommentIDs.contains($0.id) }
    }

    private var rows: [ReviewRow] {
        // Memoized against `contentKey`. The body re-evaluates on every
        // keystroke in the composer — the text is a binding — and rebuilding
        // a hundred thousand rows per character is the difference between a
        // usable surface and an unusable one. The cache is a plain class held
        // in `@State`, so reading through it does not invalidate anything.
        rowCache.rows(for: contentKey) {
            ReviewRowBuilder.rows(
                expanded: store.diff,
                comments: openComments,
                composerLineID: composer.lineID,
                editingCommentID: composer.editingCommentID,
                staleCommentIDs: store.staleCommentIDs,
                layout: reviewPresentation.diffLayout,
                source: store.source,
                gapSpans: store.gapSpans
            )
        }
    }

    /// Which lines of the open file already carry feedback. Stale comments do
    /// not mark a line: they are no longer about the line they were written on.
    private var lineCommentCounts: [Int: Int] {
        rowCache.counts(for: contentKey) {
            ReviewRowBuilder.lineCommentCounts(
                comments: store.insertableComments,
                fileID: fileID,
                lines: store.diff?.lines ?? []
            )
        }
    }

    /// Every place the query appears in the file on screen.
    var searchHits: [ReviewSearchHit] {
        guard search.isActive, !scannedQuery.isEmpty else { return [] }
        return rowCache.hits(for: contentKey + "|" + scannedQuery) {
            ReviewSearch.hits(in: rows, query: scannedQuery)
        }
    }

    /// Which match the reader is on, held inside what is actually there: a
    /// refresh, a scope change or a fold can take hits away under a position
    /// that was valid when it was set.
    private var searchPosition: Int {
        let hits = searchHits
        guard !hits.isEmpty else { return 0 }
        return min(max(search.index, 0), hits.count - 1)
    }

    private var searchTargetLineID: Int? {
        let hits = searchHits
        guard search.isActive, !hits.isEmpty else { return nil }
        return hits[searchPosition].lineID
    }

    private func openSearch() {
        guard fileID != nil else { return }
        search.isPresented = true
        // Asked for again even when it is already up: the reader may have
        // moved the keyboard elsewhere, and the Find key naming a field that
        // does not answer reads as the key having stopped working.
        findFocusRequest += 1
    }

    private func closeSearch() {
        search.isPresented = false
    }

    /// Moves the cursor to a match, which is also what scrolls to it: the
    /// table follows the selection, so the find bar does not need a scroll of
    /// its own — and the reader can carry on with `j` or `c` from where the
    /// search left them.
    private func moveSearch(by delta: Int) {
        // Only for an explicit move. Return and ⌘G answer for what is in the
        // field rather than for what the debounce has caught up with — but
        // typing arrives here as `delta == 0`, and syncing there scanned every
        // row on every keystroke and left the debounce below unreachable.
        if delta != 0, scannedQuery != search.query {
            scannedQuery = search.query
        }
        let hits = searchHits
        guard !hits.isEmpty else { return }
        search.index = ReviewSearch.step(searchPosition, by: delta, count: hits.count)
        let hit = hits[searchPosition]
        // The cursor follows only while nothing is being written. Moving the
        // selection retargets an open composer, and a draft that changed the
        // line it belongs to on every keystroke of a search would commit
        // itself somewhere the reader never chose.
        guard !composer.isOpen else { return }
        // Only onto a line a comment could be written on. `revealSearchTarget`
        // still scrolls to the others; what it does not do is leave the cursor
        // somewhere the rest of the surface refuses to act. Answered by the hit
        // rather than by scanning the rows: the find bar asks for the current
        // match on every keystroke.
        guard hit.isCommentable else { return }
        selection.select(hit.lineID, on: hit.side)
    }

    /// What the widest line can depend on, and nothing else.
    ///
    /// The column's width is measured from the text on screen, which changes
    /// with the file, with what has been unfolded, and with the layout — not
    /// with a comment's body, the composer's position, or which comments are
    /// stale. Keying that measurement on `contentKey` threw it away on every
    /// keystroke in the composer.
    private var widthKey: String {
        [
            store.diff?.fingerprint ?? "",
            fileID ?? "",
            reviewPresentation.diffLayout.rawValue,
            String(store.source.count),
            store.gapSpans.keys.sorted().map { "\($0):\(store.gapSpans[$0]?.above ?? 0):\(store.gapSpans[$0]?.below ?? 0)" }
                .joined(separator: ",")
        ].joined(separator: "|")
    }

    private var contentKey: String {
        let comments = store.comments
            // Both marks are drawn — the card carries "Inserted", and neither a
            // resolved nor a stale comment is drawn at all — so both have to
            // be able to rebuild the rows.
            .map { "\($0.id.uuidString):\($0.body.hashValue):\($0.isResolved):\($0.insertedAt != nil)" }
            .joined(separator: ",")
        return [
            store.diff?.fingerprint ?? "",
            fileID ?? "",
            String(store.files.count),
            String(composer.startLineID ?? -1),
            String(composer.lineID ?? -1),
            composer.editingCommentID?.uuidString ?? "",
            // The gutter's width is part of what the rows are laid out
            // against, so a file whose line numbers need another digit has to
            // reload rather than keep the previous file's inset.
            String(describing: numberWidth),
            store.staleCommentIDs.map(\.uuidString).sorted().joined(separator: ","),
            // The selection is deliberately not part of this. It changes
            // nothing about the row list, and keying the table's reload on it
            // rebuilt every row of the diff — a hundred thousand of them on a
            // large change — to repaint the two whose highlight moved. The
            // table redraws those two itself.
            //
            // Which layout the rows were built for, on the other hand, has to
            // be here: without it a toggle left the previous layout's rows on
            // screen.
            reviewPresentation.diffLayout.rawValue,
            // What the reader has unfolded is part of the row list, and the
            // content behind it arrives after the diff does.
            String(store.source.count),
            store.gapSpans.keys.sorted().map { "\($0):\(store.gapSpans[$0]?.above ?? 0):\(store.gapSpans[$0]?.below ?? 0)" }
                .joined(separator: ","),
            comments
        ].joined(separator: "|")
    }

    private var totals: (added: Int, removed: Int) {
        store.stats.values.reduce(into: (0, 0)) { total, stat in
            guard !stat.isBinary else { return }
            total.0 += stat.added
            total.1 += stat.removed
        }
    }

    /// What Copy hands over, which has to be what Insert would send.
    ///
    /// Built from the comments Insert would keep, not from everything open:
    /// the preview marks a stale comment and says it will not be sent, and the
    /// text beside that mark used to carry it anyway. Insert re-checks against
    /// the worktree, so this can still be a comment ahead of its file — but it
    /// is never one review already knows it is holding back.
    private var prompt: String {
        guard !store.insertableComments.isEmpty else { return "" }
        // Empty rather than thrown: the preview is a reading of the draft, and
        // a prompt that cannot be assembled is reported by Insert, which is the
        // control that acts on it.
        return (try? ReviewPromptBuilder.build(
            root: store.root,
            comments: store.insertableComments,
            instructions: settingsStore.settings.advanced.reviewInstructions
        ))?.text ?? ""
    }

    /// The composer names the run it covers, which it can only do while the
    /// first line is still in the loaded diff.
    private var composerStartLine: ReviewLine? {
        guard let start = composer.startLineID, start != composer.lineID else { return nil }
        return store.diff?.lines.first { $0.id == start }
    }

    private var canInsert: Bool {
        // Staleness no longer disables the button. It is checked again against
        // the worktree when Insert is pressed, and that path says what is
        // wrong; a button that grays out with nothing on screen explaining it
        // was worse than an error the reader can read.
        !isInserting && !isResolvingDestination && !openComments.isEmpty && destination != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.errorMessage {
                ReviewBanner(
                    systemImage: "exclamationmark.triangle.fill",
                    message: Text(verbatim: error),
                    tint: LimpidColor.error
                )
            }
            // Above the stale banner, because it explains why that one is
            // about to appear.
            if store.hasPendingChanges {
                ReviewBanner(
                    systemImage: "arrow.trianglehead.2.clockwise",
                    message: Text("The worktree has changed since this was loaded."),
                    tint: LimpidColor.secondaryText,
                    fill: LimpidColor.rowActiveFill.opacity(0.5),
                    actionTitle: "Refresh",
                    isActionEnabled: !store.isLoading && !isInserting,
                    action: { Task { await refresh() } }
                )
            }
            if staleOpenComments > 0 {
                ReviewBanner(
                    systemImage: "exclamationmark.triangle.fill",
                    message: Text(
                        "\(staleOpenComments) comments no longer match the current diff and will not be sent."
                    ),
                    tint: LimpidColor.warning,
                    actionTitle: "Show Comments",
                    isActionEnabled: !isInserting,
                    action: { isShowingPrompt = true },
                    secondaryActionTitle: "Resolve All",
                    secondaryAction: resolveStale
                )
            }
            Divider()
            HStack(spacing: 0) {
                // The list goes away entirely when the surface is too narrow to
                // hold it and a readable diff. Everything it carries — the
                // layout switch, the filter, the read marks — is also reachable
                // from the bar above the diff or from the keyboard.
                if available >= ReviewRail.minimum + ReviewRail.diffMinimum {
                    ReviewFileRail(
                        files: store.files,
                        stats: store.stats,
                        commentCounts: store.commentCounts,
                        viewed: Set(store.viewed.keys),
                        selection: fileID,
                        isTree: $isTreeLayout,
                        hidesViewed: $hidesViewedFiles,
                        onSelect: select,
                        onToggleViewed: toggleViewed,
                        available: available
                    )
                    // The grab area rides on the divider rather than beside it.
                    // Laid out as a sibling it takes six points of its own, and
                    // the diff's row colors stop at the table's edge — which
                    // read as a gap between the file list and every changed
                    // line.
                    Divider()
                        .overlay {
                            DividerResizeHandle(
                                currentWidth: { reviewPresentation.railWidth },
                                setWidth: { reviewPresentation.railWidth = $0 },
                                minWidth: ReviewRail.minimum,
                                maxWidth: max(ReviewRail.minimum, min(ReviewRail.maximum, available - ReviewRail.diffMinimum)),
                                defaultWidth: ReviewRail.default,
                                accessibilityLabel: Text("File List Width")
                            )
                        }
                }
                VStack(spacing: 0) {
                    if let file = store.files.first(where: { $0.id == fileID }) {
                        ReviewFileBar(
                            file: file,
                            stat: store.stats[file.id],
                            // Only about the file actually loaded: the rest of
                            // the list keeps the counts it was read with,
                            // which the banner above answers for.
                            isEmpty: store.diff?.file.id == file.id
                                && store.diff?.hasVanished == true,
                            isComposerOpen: composer.isOpen,
                            isViewed: store.viewed.keys.contains(file.id),
                            layout: layoutBinding,
                            onToggleViewed: { toggleViewed(file.id) }
                        )
                        Divider()
                        if search.isPresented {
                            ReviewFindBar(
                                search: $search,
                                hitCount: searchHits.count,
                                position: searchPosition,
                                onMove: moveSearch,
                                onClose: closeSearch,
                                focusRequest: findFocusRequest
                            )
                            Divider()
                        }
                    }
                    content
                    Divider()
                    ReviewFooterHints()
                }
            }
        }
        .background(LimpidColor.terminalColumnBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Before the first list, so the choice is on screen with it rather
            // than appearing a moment later.
            await store.loadBase()
            await refresh()
        }
        // The pane below can change under review — the user switches tab, an
        // agent starts or exits — and what is in front of its terminal changes
        // constantly. One cheap poll keeps the chip honest without putting a
        // process spawn in a view body.
        .task {
            while !Task.isCancelled {
                await refreshDestination()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Slower than the destination poll beside it, because each tick
        // spawns Git rather than reading a process name. Sleeping first
        // leaves the load that just ran to answer for the first interval.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await store.detectChanges()
            }
        }
        .task(id: fileID) {
            selection = ReviewSelection()
            cancelComposing()
            if let file = store.files.first(where: { $0.id == fileID }) {
                // Recorded before the load rather than after it: the load can
                // be taken over by the next file, and where the reader went is
                // true either way.
                store.rememberOpenFile(file.id)
                await store.load(file)
            }
        }
        // A pane switch re-resolves at once. Waiting for the next tick of the
        // poll showed "No terminal" for up to two seconds over a pane that has
        // one, and left Insert disabled while it said so.
        .onReceive(NotificationCenter.default.publisher(for: .limpidReviewFind)) { notification in
            guard let owner = notification.object as? WindowSession, owner === session,
                  let action = notification.userInfo?["action"] as? LimpidShortcutAction else { return }
            switch action {
            case .find: openSearch()
            case .findNext: moveSearch(by: 1)
            case .findPrevious: moveSearch(by: -1)
            default: break
            }
        }
        .onChange(of: reviewPresentation.originPaneID) { _, _ in
            resolveDestinationNow()
        }
        // Collapsing unmounts the pane and expanding mounts it again, and the
        // chip is answering for a surface that comes and goes with it. Left to
        // the poll it spent up to two seconds claiming there was no terminal
        // over one that was right there — but the destination itself has not
        // changed, so this re-probes without emptying the chip first.
        .onChange(of: reviewPresentation.isStripCollapsed) { _, _ in
            Task { await refreshDestination() }
        }
        // The scan follows the field by a moment. Long enough that a word typed
        // at speed is scanned once, short enough that the count does not read
        // as stuck.
        .task(id: search.query) {
            guard scannedQuery != search.query else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            scannedQuery = search.query
            // Landing on the first hit belongs to the scan, not to the
            // keystroke: the keystroke does not know what the hits are yet.
            moveSearch(by: 0)
        }
        .onChange(of: selection) { old, new in
            // Only while the run is still being extended. A plain click
            // somewhere else is the reader leaving, and dragging the draft
            // along committed it to lines they never selected. The anchor is
            // what says which: `follow` changes the side alone, so a layout
            // switch must not throw the draft away. An edit in progress is
            // never discarded — there is no undo for it.
            guard let start = new.startLineID, let end = new.endLineID else { return }
            if old.anchorLineID != new.anchorLineID, composer.editingCommentID == nil {
                cancelComposing()
                return
            }
            composer.retarget(start: start, end: end, side: new.side)
        }
        .onChange(of: store.diff?.fingerprint, initial: true) { _, _ in
            selection = ReviewSelection()
            cancelComposing()
            // A comment opened from the list names a line in a file that may
            // still be loading; the jump lands once the diff is here.
            if let target = pendingJump, store.diff?.file.id == target.fileID {
                selection.select(target.start, on: target.side)
                if target.end != target.start {
                    selection.extend(to: target.end)
                }
                pendingJump = nil
            }
            numberWidth = ReviewRowMetrics.numberWidth(forHighestLine: highestLine)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(LimpidColor.secondaryText)
            Text("Review changes")
                .font(LimpidFont.headline)
            Text(verbatim: store.root.lastPathComponent)
                .font(LimpidFont.caption)
                .foregroundStyle(LimpidColor.secondaryText)
                .lineLimit(1)
                .textSelection(.enabled)
            scopePicker
            statPill
            Spacer(minLength: 8)
            Text("Insert into")
                .font(LimpidFont.caption)
                .foregroundStyle(LimpidColor.tertiaryText)
            ReviewDestinationChip(destination: destination, isResolving: isResolvingDestination)
            commentPill
            Button("Refresh") { Task { await refresh() } }
                .accessibilityLabel(Text("Refresh"))
                .disabled(store.isLoading || isInserting)
            // The surface is a review; the button does not have to say so
            // again. It keeps the full phrase for VoiceOver, where the reader
            // may be arriving from anywhere in the window.
            Button("Insert", action: insert)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(Text("Insert Review"))
                .disabled(!canInsert)
            // Never disabled, not even mid-insert: validation runs Git once
            // per commented file, and a surface that cannot be closed while
            // that happens is a surface that can be stuck. The insert task
            // re-checks its target before writing anything.
            Button("Close", action: onClose)
                .accessibilityLabel(Text("Close"))
                // Escape belongs to whatever is open inside the surface first:
                // the composer holds a draft, and the find bar is what the
                // reader means to dismiss while it is up.
                .keyboardShortcut(composer.isOpen || search.isPresented ? nil : .cancelAction)
            // Off screen: ⌘F is a shortcut, not a control the header has room
            // to name. Zero-sized rather than `.hidden()`, which would take
            // the shortcut with it.

        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(LimpidColor.tabColumnBackground)
    }

    private var statPill: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(totals.added)")
                .foregroundStyle(LimpidColor.success)
            Text(verbatim: "−\(totals.removed)")
                .foregroundStyle(LimpidColor.error)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .overlay(Capsule().stroke(LimpidColor.panelDivider))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Changed lines"))
    }

    /// What the review is of. In the header rather than over the file list,
    /// because it decides the stats and the diff beside it as much as the
    /// list — and because a popover for a choice between two is a window
    /// opened over the thing the reader is trying to see.
    ///
    /// Absent in a repository with no branch to compare against: an offer of
    /// one option is not a choice.
    @ViewBuilder
    private var scopePicker: some View {
        if let base = store.base {
            ReviewScopeSwitch(
                base: base,
                isBranch: store.scope != .uncommitted,
                isEnabled: !store.isLoading && !isInserting
            ) { isBranch in
                Task { await changeScope(isBranch ? .branch(base: base) : .uncommitted) }
            }
        }
    }

    private var commentPill: some View {
        Button {
            isShowingPrompt.toggle()
        } label: {
            Label {
                Text(verbatim: "\(store.insertableComments.count)")
                    .font(.caption.monospacedDigit())
            } icon: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
        }
        .disabled(store.comments.isEmpty)
        .accessibilityLabel(Text("Preview the comments to insert"))
        .accessibilityValue(Text(verbatim: "\(store.insertableComments.count)"))
        .help(Text("Preview what will be inserted"))
        .popover(isPresented: $isShowingPrompt, arrowEdge: .bottom) {
            ReviewPromptPreview(store: store, prompt: prompt, onJump: jump)
        }
    }

    private var layoutBinding: Binding<ReviewDiffLayout> {
        Binding(
            get: { reviewPresentation.diffLayout },
            set: { setLayout($0) }
        )
    }

    private func setLayout(_ layout: ReviewDiffLayout) {
        guard layout != reviewPresentation.diffLayout else { return }
        reviewPresentation.diffLayout = layout
        let head = selection.headLineID.flatMap { id in store.diff?.lines.first { $0.id == id } }
        selection.follow(layout, head: head, lines: store.diff?.lines ?? [])
    }

    private func toggleViewed(_ fileID: String) {
        store.setViewed(fileID, !store.viewed.keys.contains(fileID))
    }

    /// Resolves everything the worktree has moved past, in one action, with the
    /// draft it replaced held for the length of the toast.
    private func resolveStale() {
        let before = openComments.count
        guard let previous = store.resolveStale() else { return }
        let committed = store.comments
        let resolved = before - openComments.count
        toastCenter.show(ToastItem(
            message: String(localized: "Resolved \(resolved) comments."),
            undo: { store.restore(previous, from: committed) }
        ))
    }

    private func jump(to comment: ReviewComment) {
        isShowingPrompt = false
        // The preview lists every comment in the draft, whichever view it was
        // written in, so the one the reader picked can name a layer this scope
        // does not carry. Its file id is then in no list, nothing loads, and
        // the diff of the file that was open stays on screen under a file bar
        // that has gone — so the scope moves to the comment before the file
        // does. Without a base there is no branch view to move to, and a
        // branch comment cannot be reached at all.
        if !store.scope.layers.contains(comment.file.layer) {
            guard let base = store.base else { return }
            Task {
                await changeScope(comment.file.layer == .branch ? .branch(base: base) : .uncommitted)
                jump(to: comment)
            }
            return
        }
        pendingJump = ReviewJump(
            fileID: comment.file.id,
            start: comment.lineID,
            end: comment.lastLineID,
            side: comment.side
        )
        if fileID == comment.file.id {
            selection.select(comment.lineID, on: comment.side)
            if comment.lastLineID != comment.lineID {
                selection.extend(to: comment.lastLineID)
            }
            // A comment written in the unified layout has no column; landing on
            // it in the split one has to pick the column that draws it, the
            // same way a layout switch does.
            let head = store.diff?.lines.first { $0.id == comment.lastLineID }
            selection.follow(reviewPresentation.diffLayout, head: head, lines: store.diff?.lines ?? [])
            pendingJump = nil
        } else {
            select(comment.file.id)
        }
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if store.files.isEmpty, !store.isLoading, store.hasLoaded, !store.hasListRefreshFailed {
                Text("No changes to review.")
                    .foregroundStyle(LimpidColor.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReviewDiffTable(
                    rows: rows,
                    diffLines: store.diff?.lines ?? [],
                    contentKey: contentKey,
                    widthKey: widthKey,
                    layout: reviewPresentation.diffLayout,
                    files: listedFiles,
                    lineCommentCounts: lineCommentCounts,
                    numberWidth: numberWidth,
                    expandedFileID: fileID,
                    contentIdentity: (fileID ?? "") + "|" + (store.diff?.fingerprint ?? ""),
                    selection: $selection,
                    composerLineID: composer.lineID,
                    composerStartLine: composerStartLine,
                    composerIsEditing: composer.editingCommentID != nil,
                    composerText: $composer.text,
                    onSelectFile: { select($0.id) },
                    onCompose: beginComposing,
                    onCancelCompose: cancelComposing,
                    onCommit: commitComposer,
                    onInsert: {
                        if canInsert {
                            insert()
                        }
                    },
                    onToggleTerminal: toggleTerminal,
                    search: search.isActive ? search : ReviewSearch(query: "", isPresented: search.isPresented),
                    onCloseSearch: closeSearch,
                    searchTargetLineID: searchTargetLineID,
                    language: store.diff.map { ReviewSyntax.language(for: $0.file.path) } ?? nil,
                    onToggleViewed: {
                        if let fileID {
                            toggleViewed(fileID)
                        }
                    },
                    onExpand: { store.expand($0, $1) },
                    onResolve: { store.setResolved($0.id, true) },
                    onEdit: beginEditing,
                    onDelete: { store.remove($0.id) },
                    onClose: onClose
                )
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if isSlowToLoad {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
                    // Over the diff, not in place of it: the list stays
                    // readable and clickable while one file is being read.
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text("Loading changes…"))
            }
        }
        // Delayed for the same reason the open is: a warm file arrives inside
        // a frame or two, and a spinner that appears and leaves in that time
        // reads as a fault rather than as progress.
        .task(id: store.isLoading) {
            guard store.isLoading else {
                isSlowToLoad = false
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            isSlowToLoad = !Task.isCancelled && store.isLoading
        }
    }
}
