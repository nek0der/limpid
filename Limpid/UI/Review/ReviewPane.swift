// ReviewPane.swift
// Limpid — the review tab's surface, drawn where the terminal it writes back to was.

import AppKit
import SwiftUI

/// How long the review waits before saying it is still opening or still
/// loading: long enough that a warm read never flashes a spinner. One value
/// for the open and the load, which read as one wait.
enum ReviewLoadingTiming {
    static let spinnerDelay: Duration = .milliseconds(250)
}

struct ReviewPane: View {
    let directory: URL
    /// How wide the surface is. Handed down from the pane area rather than
    /// measured here: a geometry reader in this body would rebuild the diff
    /// table on every frame of a divider drag.
    let available: CGFloat
    let onClose: () -> Void
    var onInserted: ((UUID) -> Void)?
    /// The review to show, which its owner keeps across showings (the
    /// window's review tab, `ProjectWindowState.reviewSession`). The surface
    /// opens no review of its own: one drawn in place of the owner's would
    /// take a comment the window never sees. `nil` draws none.
    var session: ReviewSession?

    @Environment(\.reviewTabHandler) private var reviewTabHandler
    @Environment(ProjectWindowState.self) private var window
    /// `session`, once its worktree resolves to the review's own.
    @State private var reviewSession: ReviewSession?
    @State private var failure: DisplayText?
    /// Bumped by Try Again. The open is keyed on it as well as on the
    /// directory, so asking again re-runs it without the reader having to
    /// close review and come back.
    @State private var reloadToken = 0
    /// Whether the open has taken long enough to be worth saying so.
    @State private var isSlowToOpen = false

    var body: some View {
        Group {
            if let reviewSession {
                ReviewWorkspaceView(
                    reviewSession: reviewSession,
                    available: available,
                    onClose: onClose,
                    onInserted: onInserted
                )
                // Retargeting to another worktree keeps this view's identity,
                // which would otherwise carry the previous root's selection
                // and composer into a diff they do not belong to.
                .id(reviewSession.root)
            } else {
                VStack(spacing: 0) {
                    loadingView
                    // The review tab's band stays while its review opens, or
                    // fails to: its Close is the way out, and a row that came
                    // and went would move everything above it.
                    if let tab = window.review, let reviewTabHandler {
                        ReviewTabBand(tab: tab, reviewSession: window.reviewSession, handler: reviewTabHandler)
                    }
                }
            }
        }
        .task(id: [directory.path, String(reloadToken)]) { await loadSession() }
    }

    /// What stands in until the repository is resolved.
    ///
    /// Deliberately empty for the first quarter second. Resolving the root is
    /// one `rev-parse`, so on a repository that is already warm the spinner
    /// appeared and left inside a frame or two — a flash the reader reads as
    /// the surface failing to open rather than as it opening. It is the wait
    /// that needs explaining, not the open.
    private var loadingView: some View {
        VStack(spacing: LimpidLayout.Supervision.spaceL) {
            if let failure {
                // A comment the review cannot show is offered here: the tab
                // can be closed once it is copied or thrown away.
                if let session {
                    ReviewUnplacedCommentBanner(reviewSession: session)
                }
                Text(display: failure)
                HStack(spacing: LimpidLayout.Supervision.spaceM) {
                    // The messages that land here name a retry — "Refresh to
                    // try again". No Close beside it: the band under this
                    // carries the tab's (one place for a button).
                    Button("Try Again") { reloadToken += 1 }
                        .accessibilityLabel(Text("Try Again"))
                }
            } else if isSlowToOpen {
                ProgressView("Loading changes…")
            }
        }
        // No fill of its own: the review tab stands on the session's
        // surface, as the terminal it replaces does.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: directory) {
            isSlowToOpen = false
            try? await Task.sleep(for: ReviewLoadingTiming.spinnerDelay)
            isSlowToOpen = !Task.isCancelled
        }
    }

    private func loadSession() async {
        failure = nil
        guard let session else { return }
        do {
            let root = try await ReviewGit.root(at: directory)
            try Task.checkCancellation()
            // Nothing to do when this task ran again for the repository
            // already on screen: clearing the review session would start the
            // one that replaced it over, in another scope with no open file.
            // The previous target's surface still goes away before another
            // repository's arrives: left up, its diff and its Insert button
            // would belong to a worktree the reader had already navigated
            // away from.
            guard reviewSession?.root != root else { return }
            open(ReviewPaneOpening.choose(kept: session, resolved: .success(root)), kept: session)
        } catch is CancellationError {
            // A newer directory took over; that task owns the screen now.
        } catch {
            open(ReviewPaneOpening.choose(kept: session, resolved: .failure(error)), kept: session)
        }
    }

    private func open(_ choice: ReviewPaneOpening.Choice, kept: ReviewSession) {
        switch choice {
        case .kept:
            reviewSession = kept
        case let .cannotOpen(message):
            // The review tab's comment cannot be shown with no review to
            // show it in, nor kept unseen: it goes to the banner this
            // screen draws.
            kept.setComposerAside()
            // The surface belongs to a repository we could not resolve.
            // Leaving the previous one up left its diff and its Insert button
            // pointed at a worktree the reader had navigated away from — and
            // the message below is drawn where the review session is not, so
            // without this it was never shown at all.
            reviewSession = nil
            failure = message
        }
    }
}

struct ReviewWorkspaceView: View {
    let reviewSession: ReviewSession
    @Environment(\.isReviewInFront) private var isReviewInFront
    @Environment(\.reviewTabHandler) var reviewTabHandler
    /// The opening of the review tab this view draws. The window's tab can
    /// change under a view that is going (`ReviewViewWork`).
    @Environment(\.reviewTabOpening) var reviewTabOpening
    /// Raised when the review tab comes back in front, so the diff takes the
    /// keyboard (`ReviewDiffTable.focusRequest`).
    @State private var tableFocusRequest = 0
    @Environment(ProjectWindowState.self) var window
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

    @Environment(WorkspaceSession.self) var session
    @Environment(ReviewPresentation.self) var reviewPresentation
    @Environment(\.surfaceRegistry) var registry
    @Environment(ToastCenter.self) var toastCenter
    @Environment(SettingsStore.self) var settingsStore
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.supervisionSurfaceOpacity) private var surfaceOpacity
    @Environment(\.locale) var locale
    @State var fileID: String?
    /// The line run a comment will cover and the text dragged for copying,
    /// held together so that only one of them is highlighted at a time.
    @State var selection = ReviewDiffSelection()
    /// Editing reuses the composer rather than opening a modal on top of a
    /// surface that already covers the window, so which comment is being
    /// rewritten has to travel with it. The review's own
    /// (`ReviewSession.composer`), so a surface drawn anew, for a review tab
    /// that comes back, draws the comment it was left with.
    var composer: ReviewComposerState {
        get { reviewSession.composer }
        nonmutating set { reviewSession.composer = newValue }
    }

    /// Polled rather than computed: resolving what is in front of the pane's
    /// terminal blocks on a `sysctl` and, under tmux hosting, on tmux itself.
    @State var destination: ReviewDestination?
    /// What runs in front of each pane the band's destination menu offers,
    /// by pane, so each item says what it would write into, as the band
    /// does for the chosen one. Polled with `destination`, for the same
    /// reason.
    @State var choiceForegrounds: [UUID: String] = [:]
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
    /// band claims there is no terminal while it is still looking.
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
    /// The checked files opened again from their headers.
    @State var openedViewedFiles = ReviewStackOpenedFiles()
    /// The file list becomes a transient drawer when it cannot coexist with a
    /// readable diff. This is presentation state, not a saved review choice.
    @State var isCompactFileRailPresented = false
    /// The drawer stays mounted until its closing offset reaches the edge;
    /// removing it early would discard the animation's source view.
    @State var isCompactFileRailMounted = false
    @State var search = ReviewSearch()
    /// One number column, sized to the file being read. Stored rather than
    /// computed: the scan is over every line of the diff, and a computed
    /// property would repeat it on every keystroke in the composer.
    @State var numberWidth = ReviewRowMetrics.defaultNumberWidth
    /// Whether this opening's first read has answered. Until then the
    /// surface shows that it is loading, not an empty list it has not read.
    @State var hasPreparedInitialSnapshot = false
    /// The file the stacked diff was last asked to put at its top.
    @State var stackScroll = ReviewStackScroll()
    /// Where the tab that came back was scrolled, until put back (`takeStackRestore`).
    @State var stackRestore: ReviewScrollAnchor?
    /// The paths the stacked diff's headers mark "Changed Outside Turns".
    @Environment(\.reviewPathsOutsideTurns) var pathsOutsideTurns
    /// The conversations whose turns changed each file, by path, for the
    /// stacked diff's headers.
    @Environment(\.reviewFileTags) var fileTags

    /// The comments that still stand. Resolved ones stay in the draft as the
    /// record of what was asked, and leave everything that acts on a comment:
    /// the diff, the counts, and the prompt.
    var openComments: [ReviewComment] {
        reviewSession.shownComments.filter { !$0.isResolved }
    }

    /// The files the reader is being shown, which is what `n` and `p` walk.
    ///
    /// The open one stays whatever its mark says: a list that denied the file
    /// on screen was there would be answering a different question from the
    /// diff beside it. The rail narrows this further by its own text filter,
    /// which is a search rather than a scope and does not belong here.
    var listedFiles: [ReviewFile] {
        // In the order the rail draws them, which is what `n` and `p` walk.
        ReviewFileTree.listed(
            ReviewFileTree.ordered(reviewSession.files, isTree: isTreeLayout),
            hidingViewed: hidesViewedFiles,
            viewed: Set(reviewSession.viewed.keys),
            open: fileID
        )
    }

    /// The largest line number the gutter may ever have to draw.
    ///
    /// The stacked diff draws every file's numbers in one gutter, as wide as
    /// the range has needed (`ReviewStackLoader.highestLine`, the open file's
    /// whole content included: unfolding reveals numbers the diff never
    /// showed); it does not narrow for a short file, which would shift every
    /// line of the diff sideways as the reader read on.
    private var highestLine: Int {
        let patch = reviewSession.diff?.lines.reduce(0) { highest, line in
            max(highest, max(line.oldLine ?? 0, line.newLine ?? 0))
        } ?? 0
        return max(reviewSession.stackLoader.highestLine, patch, Self.stackedGutterFloor)
    }

    /// How many comments the banner is about. A resolved comment can also be
    /// stale — resolving is what the banner's own bulk action does to them —
    /// and counting those would leave it standing with nothing left to act on.
    private var staleOpenComments: Int {
        openComments.count { reviewSession.staleCommentIDs.contains($0.id) }
    }

    /// The open file's rows, which the stack draws in its place
    /// (`ReviewStackBuilder.Input.openRows`).
    var openRows: [ReviewRow] {
        // Memoized against `openRowsKey`. The body re-evaluates on every
        // keystroke in the composer — the text is a binding — and rebuilding
        // a hundred thousand rows per character is the difference between a
        // usable surface and an unusable one. The cache is a plain class held
        // in `@State`, so reading through it does not invalidate anything.
        rowCache.rows(for: openRowsKey) {
            ReviewRowBuilder.rows(
                expanded: reviewSession.diff,
                comments: openComments,
                composerLineID: composer.lineID,
                editingCommentID: composer.editingCommentID,
                staleCommentIDs: reviewSession.staleCommentIDs,
                layout: reviewPresentation.diffLayout,
                source: reviewSession.source,
                gapSpans: reviewSession.gapSpans
            )
        }
    }

    /// Which lines of the open file already carry feedback. Stale comments do
    /// not mark a line: they are no longer about the line they were written on.
    var openLineCommentCounts: [Int: Int] {
        rowCache.counts(for: openRowsKey) {
            ReviewRowBuilder.lineCommentCounts(
                comments: reviewSession.insertableComments,
                fileID: fileID,
                lines: reviewSession.diff?.lines ?? []
            )
        }
    }

    /// Every place the query appears in the files read.
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
        guard fileID != nil, !isCompactFileRailPresented else { return }
        search.isPresented = true
        loadStackForSearch()
        // Asked for again even when it is already up: the reader may have
        // moved the keyboard elsewhere, and the Find key naming a field that
        // does not answer reads as the key having stopped working.
        findFocusRequest += 1
    }

    private func closeSearch() {
        search.isPresented = false
        reviewSession.stackLoader.endSearch()
    }

    /// Moves the cursor to a match, which is also what scrolls to it: the
    /// table follows the selection, so the find bar does not need a scroll of
    /// its own — and the reader can carry on with `j` or `c` from where the
    /// search left them.
    private func moveSearch(by delta: Int) {
        guard !isCompactFileRailPresented else { return }
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
        selection.updateLines { $0.select(hit.lineID, on: hit.side) }
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
            reviewSession.diff?.fingerprint ?? "",
            fileID ?? "",
            reviewPresentation.diffLayout.rawValue,
            String(reviewSession.source.count),
            reviewSession.gapSpans.keys.sorted()
                .map { "\($0):\(reviewSession.gapSpans[$0]?.above ?? 0):\(reviewSession.gapSpans[$0]?.below ?? 0)" }
                .joined(separator: ",")
        ].joined(separator: "|") + "|" + stackKey
    }

    /// What the table reloads on: the rows, and the gutter's width they are
    /// laid out against.
    var contentKey: String {
        // The gutter's width is part of what the rows are laid out
        // against, so a file whose line numbers need another digit has to
        // reload rather than keep the previous file's inset.
        openRowsKey + "|" + String(describing: numberWidth) + "|" + stackKey
    }

    /// What the open file's rows depend on.
    var openRowsKey: String {
        // Every mark changes what is drawn — the card carries "Inserted",
        // and a resolved or stale comment is not drawn at all — so each has
        // to be able to rebuild the rows.
        let comments = ReviewCommentRenderKey.of(reviewSession.shownComments, stale: reviewSession.staleCommentIDs)
        return [
            reviewSession.diff?.fingerprint ?? "",
            fileID ?? "",
            String(reviewSession.files.count),
            String(composer.startLineID ?? -1),
            String(composer.lineID ?? -1),
            composer.editingCommentID?.uuidString ?? "",
            reviewSession.staleCommentIDs.map(\.uuidString).sorted().joined(separator: ","),
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
            String(reviewSession.source.count),
            reviewSession.gapSpans.keys.sorted()
                .map { "\($0):\(reviewSession.gapSpans[$0]?.above ?? 0):\(reviewSession.gapSpans[$0]?.below ?? 0)" }
                .joined(separator: ","),
            comments
        ].joined(separator: "|")
    }

    /// What Copy hands over, which has to be what Insert would send.
    ///
    /// Built from the comments Insert would keep, not from everything open:
    /// the preview marks a stale comment and says it will not be sent, so the
    /// text beside that mark must not carry it. Insert re-checks against
    /// the worktree, so this can still be a comment ahead of its file — but it
    /// is never one review already knows it is holding back.
    var prompt: String {
        guard !reviewSession.insertableComments.isEmpty else { return "" }
        // Empty rather than thrown: the preview is a reading of the draft, and
        // a prompt that cannot be assembled is reported by Insert, which is the
        // control that acts on it.
        return (try? ReviewPromptBuilder.build(
            root: reviewSession.root,
            comments: reviewSession.insertableComments,
            instructions: settingsStore.settings.advanced.reviewInstructions,
            locale: settingsStore.appLocale
        ))?.text ?? ""
    }

    /// The composer names the run it covers, which it can only do while the
    /// first line is still in the loaded diff.
    private var composerStartLine: ReviewLine? {
        guard let start = composer.startLineID, start != composer.lineID else { return nil }
        return reviewSession.diff?.lines.first { $0.id == start }
    }

    private var canInsert: Bool {
        // Staleness no longer disables the button. It is checked again against
        // the worktree when Insert is pressed, and that path says what is
        // wrong; a button that grays out with nothing on screen explaining it
        // was worse than an error the reader can read.
        // The review tab's pane can close between two probes; the band
        // already says so, and the button agrees at once.
        let isPaneOpen = window.review.map { reviewTabHandler?.isDestinationOpen($0) ?? false } ?? false
        return !isInserting && !isResolvingDestination && !openComments.isEmpty && destination != nil && isPaneOpen
    }

    /// The diff column: the find bar over the stacked diff. The range's size
    /// and the layout are in the tab's top edge (`ReviewStackBar`), and each
    /// file's own name is on its header in the diff.
    var diffColumn: some View {
        VStack(spacing: 0) {
            findBar
            // The review tab writes its keys in the menus, the tooltips, and
            // the shortcut list rather than along its foot (no standing
            // notes).
            content
        }
    }

    @ViewBuilder
    var findBar: some View {
        if search.isPresented {
            ReviewFindBar(
                search: $search,
                hitCount: searchHits.count,
                position: searchPosition,
                onMove: moveSearch,
                onClose: closeSearch,
                focusRequest: findFocusRequest,
                note: findNote
            )
            Divider()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let tab = window.review, let reviewTabHandler {
                tabTop(tab, handler: reviewTabHandler)
            }
            ReviewLegacyComments(reviewSession: reviewSession)
            ReviewUnplacedCommentBanner(reviewSession: reviewSession)
            if let error = reviewSession.errorMessage {
                ReviewBanner(
                    systemImage: "exclamationmark.triangle.fill",
                    message: Text(display: error),
                    tone: .error
                )
            }
            // Above the stale banner, because it explains why that one is
            // about to appear.
            if reviewSession.hasPendingChanges {
                ReviewBanner(
                    systemImage: "arrow.trianglehead.2.clockwise",
                    message: Text("Files in the worktree changed after this was loaded."),
                    tone: .notice,
                    actionTitle: "Refresh",
                    isActionEnabled: !reviewSession.isLoading && !isInserting,
                    action: { Task { await refresh() } }
                )
            }
            if staleOpenComments > 0 {
                ReviewBanner(
                    systemImage: "exclamationmark.triangle.fill",
                    message: Text(
                        "\(staleOpenComments) comments no longer match the current diff and won’t be sent."
                    ),
                    tone: .warning,
                    actionTitle: "Show Comments",
                    isActionEnabled: !isInserting,
                    action: { isShowingPrompt = true },
                    secondaryActionTitle: "Resolve All",
                    secondaryAction: resolveStale
                )
            }
            Divider()
            ZStack {
                if hasPreparedInitialSnapshot {
                    reviewContentArea
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
                if isSlowToLoad {
                    ProgressView()
                        .controlSize(.small)
                        .padding(LimpidLayout.Supervision.spaceS)
                        // Floating over the diff, on the floating parts'
                        // ground: opaque while transparency is off or reduced.
                        .background(FloatingPanelFill(shape: Capsule()))
                        .allowsHitTesting(false)
                        .accessibilityLabel(Text("Loading changes…"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The review tab's band, which carries this review's insert:
            // the destination it polls and the comments it would send.
            if let tab = window.review, let reviewTabHandler {
                ReviewTabBand(
                    tab: tab,
                    reviewSession: reviewSession,
                    handler: reviewTabHandler,
                    insert: ReviewTabInsert(
                        destination: destination,
                        isResolving: isResolvingDestination,
                        choiceForegrounds: choiceForegrounds,
                        count: openComments.count,
                        canInsert: canInsert,
                        isInserting: isInserting,
                        onInsert: insert
                    )
                )
            }
        }
        // No fill of its own: the review tab stands on the session's
        // surface, as the terminal it replaces does.
        // Exactly the width it was given, and cut there: a stack is as
        // wide as its widest child, so one row that asked for more (the
        // band once did) laid the whole review out past the column, with
        // its right side out of sight.
        .frame(width: available)
        .frame(maxHeight: .infinity)
        .clipped()
        // A warm read should not flash a spinner, but a slow initial read must
        // still explain the otherwise empty protected snapshot area.
        .task(id: reviewSession.isLoading) {
            guard reviewSession.isLoading else {
                isSlowToLoad = false
                return
            }
            try? await Task.sleep(for: ReviewLoadingTiming.spinnerDelay)
            isSlowToLoad = !Task.isCancelled && reviewSession.isLoading
        }
        .onChange(of: showsInlineFileRail) { _, isInline in
            if isInline {
                isCompactFileRailPresented = false
                isCompactFileRailMounted = false
            }
        }
        .onDisappear {
            isCompactFileRailPresented = false
            isCompactFileRailMounted = false
        }
        // The review tab comes back as it was left, after going with its
        // project (`ReviewTabViewState`).
        .keptInReviewTab($isTreeLayout, as: \.isTreeLayout)
        .keptInReviewTab($hidesViewedFiles, as: \.hidesViewedFiles)
        .keptInReviewTab($openedViewedFiles, as: \.openedViewedFiles)
        .onChange(of: reviewSession.viewed) { _, viewed in
            openedViewedFiles.prune(viewed: viewed)
        }
        // Counted already: the find bar comes back on the match it was on,
        // rather than landing on the first and moving the cursor there.
        .keptInReviewTab($search, as: \.search) { scannedQuery = $0.query }
        .onAppear(perform: takeStackRestore)
        .onExitCommand {
            if isCompactFileRailPresented {
                dismissCompactFileRail()
            } else if !composer.isOpen, !search.isPresented {
                onClose()
            }
        }
        .task { await readFirst() }
        .onChange(of: reviewPresentation.scopeRequestID) { _, _ in
            guard let requestedScope = reviewPresentation.requestedScope else { return }
            Task { await changeScope(requestedScope) }
        }
        // The pane below can change under review — the user switches tab, an
        // agent starts or exits — and what is in front of its terminal changes
        // constantly. One cheap poll keeps the band's destination honest
        // without putting a process spawn in a view body.
        .task(id: isReviewInFront) {
            // The menu's other panes are read on every tick only while the
            // tab writes nowhere, when the band offers them as the next
            // step; otherwise on every third, for a menu that is opened
            // now and then.
            var tick = 0
            while isReviewInFront, !Task.isCancelled {
                await refreshDestination()
                if destination == nil || tick.isMultiple(of: 3) {
                    await refreshChoiceForegrounds()
                }
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Slower than the destination poll beside it, because each tick
        // spawns Git rather than reading a process name. It asks at once
        // each time the review tab comes to the front: what changed while
        // the tab was behind a terminal tab is news now.
        .task(id: isReviewInFront) {
            while isReviewInFront, !Task.isCancelled {
                await reviewSession.detectChanges()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: isReviewInFront) { _, isInFront in
            if isInFront {
                tableFocusRequest += 1
            }
        }
        .onWindowCommand(of: window) { command in
            // The review of the window Find was asked in. The review is
            // drawn only by `PaneAreaView` and the review tab inside it, in a
            // main window, whose `MainWindowContent` puts the window in the
            // environment.
            guard case let .reviewFind(action) = command else { return false }
            switch action {
            case .find: openSearch()
            case .findNext: moveSearch(by: 1)
            case .findPrevious: moveSearch(by: -1)
            default: break
            }
            return true
        }
        // A pane switch re-resolves at once. Waiting for the next tick of the
        // poll showed "No terminal" for up to two seconds over a pane that has
        // one, and left Insert disabled while it said so.
        .onChange(of: reviewPresentation.originPaneID) { _, _ in
            resolveDestinationNow()
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
        .onChange(of: composer.isOpen) { _, isOpen in
            if !isOpen {
                selection.composerDidClose()
            }
        }
        .onChange(of: selection.lines) { old, new in
            // A cursor or a run that reached another file of the stacked
            // diff opens that file and lands there.
            if routeIntoStack(new) {
                return
            }
            // Only while the run is still being extended. A plain click
            // somewhere else is the reader leaving, and dragging the draft
            // along committed it to lines they never selected. The anchor is
            // what says which: `follow` changes the side alone, so a layout
            // switch must not throw the draft away. An edit in progress is
            // never discarded — there is no undo for it.
            // A composer already on the new run was opened for it in the same
            // keystroke — `c` on dragged text picks the run and composes at
            // once — so that change is not the reader leaving.
            guard let start = new.startLineID, let end = new.endLineID else { return }
            switch ReviewComposerSelection.change(
                of: composer,
                holdsText: reviewSession.composerHoldsUnsavedText,
                from: old,
                to: new
            ) {
            case .keep:
                break
            case .retarget:
                composer.retarget(start: start, end: end, side: new.side)
            case .cancel:
                cancelComposing()
            }
        }
        // A fingerprint describes content, not identity. Two files can have
        // the same patch, so include the file id or a selection and pending
        // jump from the previous file can survive the switch.
        .onChange(of: reviewSession.diff.map { $0.file.id + "|" + $0.fingerprint }, initial: true) { _, _ in
            selection.clear()
            // A comment being written has followed the diff already, in the
            // review (`ReviewComposerFollow`): onto the same code, or into
            // the banner. An empty composer closes with the lines it was on.
            if !composer.hasUnsavedText {
                cancelComposing()
            }
            // A comment opened from the list names a line in a file that may
            // still be loading; the jump lands once the diff is here.
            landPendingJump()
            numberWidth = ReviewRowMetrics.numberWidth(forHighestLine: highestLine)
        }
        // The stacked diff's gutter widens as files with longer line numbers
        // are read, and the open file's contents arrive after its diff.
        .onChange(of: reviewSession.stackLoader.highestLine) { _, _ in
            numberWidth = ReviewRowMetrics.numberWidth(forHighestLine: highestLine)
        }
        // A composer that closes lets go of the stack's hold in any case.
        .onChange(of: composer.isOpen, initial: true) { _, isOpen in
            if !isOpen {
                holdStack(isComposingInputMethodText: false)
            }
        }
        // Find stays open across a refresh or another range, and searches
        // what the list now holds.
        .onChange(of: reviewSession.listReadCount) { _, _ in
            guard search.isPresented else { return }
            loadStackForSearch()
        }
        // Cards, composers and expanded gaps can move the same code to another
        // rendered row. Rebase by line identity and clear only if an endpoint
        // actually disappeared.
        .onChange(of: contentKey) { _, _ in
            selection.rebaseText(in: rows)
        }
    }

    var layoutBinding: Binding<ReviewDiffLayout> {
        Binding(
            get: { reviewPresentation.diffLayout },
            set: { setLayout($0) }
        )
    }

    private func setLayout(_ layout: ReviewDiffLayout) {
        guard layout != reviewPresentation.diffLayout else { return }
        reviewPresentation.diffLayout = layout
        selection.clearText()
        let head = selection.lines.headLineID.flatMap { id in reviewSession.diff?.lines.first { $0.id == id } }
        selection.updateLines { $0.follow(layout, head: head, lines: reviewSession.diff?.lines ?? []) }
    }

    // MARK: - Content

    private var content: some View {
        Group {
            if !hasPreparedInitialSnapshot {
                Color.clear
                    .accessibilityHidden(true)
            } else if reviewSession.files.isEmpty, reviewSession.hasLoaded, !reviewSession.hasListRefreshFailed {
                // The review tab reads a range, and says so of it.
                SupervisionEmptyState(.noChangesInScope, size: .regular)
            } else {
                ReviewDiffTable(
                    stack: stack,
                    diffLines: reviewSession.diff?.lines ?? [],
                    contentKey: contentKey,
                    widthKey: widthKey,
                    layout: reviewPresentation.diffLayout,
                    files: listedFiles,
                    numberWidth: numberWidth,
                    expandedFileID: fileID,
                    isInteractionEnabled: !reviewSession.isLoading,
                    selection: $selection,
                    composerLineID: composer.lineID,
                    composerStartLine: composerStartLine,
                    composerIsEditing: composer.editingCommentID != nil,
                    composerText: Binding(get: { composer.text }, set: { composer.text = $0 }),
                    onSelectFile: { select($0.id) },
                    onCompose: beginComposing,
                    onCancelCompose: cancelComposing,
                    onCommit: commitComposer,
                    onInsert: {
                        // ⌘⏎ in the review tab is the band's "Mark as Viewed";
                        // inserting is the button's.
                        reviewTabHandler?.primaryKey()
                    },
                    search: search.isActive ? search : ReviewSearch(query: "", isPresented: search.isPresented),
                    onCloseSearch: closeSearch,
                    searchTargetLineID: searchTargetLineID,
                    language: reviewSession.diff.map { ReviewSyntax.language(for: $0.file.path) } ?? nil,
                    onToggleViewed: {
                        if let fileID {
                            toggleViewed(fileID)
                        }
                    },
                    focusRequest: tableFocusRequest,
                    fileApplication: FileOpener.application(
                        for: settingsStore.settings.advanced.fileApplication
                    ),
                    onOpenLine: openInEditor(line:fileID:),
                    onExpand: { reviewSession.expand($0, $1) },
                    onResolve: { reviewSession.setResolved($0.id, true) },
                    onEdit: beginEditing,
                    onDelete: { reviewSession.remove($0.id) },
                    hunkActions: hunkActions,
                    onDiscardHunk: { hunk, fileID in
                        hunkCall(hunk, in: fileID) { handler, tab, file, header in handler.discardHunk(tab, file, header, locale) }
                    },
                    onUndoDiscard: { hunk, fileID in
                        hunkCall(hunk, in: fileID) { handler, tab, file, header in handler.undoDiscard(tab, file, header, locale) }
                    },
                    onCommentHunk: commentOnHunk(_:in:),
                    surfaceOpacity: surfaceOpacity,
                    scrollRequest: stackScroll,
                    stackRestore: stackRestore,
                    onStackRestored: stackRestoreFinished,
                    onScrollReader: stackScrollReader,
                    onNeedDiffs: { reviewSession.loadStacked(window: $0) },
                    onComposerInputMethodText: holdStack(isComposingInputMethodText:),
                    onReadingFile: readOn,
                    onToggleFileViewed: toggleViewed,
                    onToggleFileFold: toggleFold,
                    root: reviewSession.root,
                    isOverlayPresented: isCompactFileRailPresented,
                    onCloseOverlay: dismissCompactFileRail,
                    onClose: onClose,
                    locale: locale
                )
            }
        }
        .task(id: hunkDiscardKey) {
            guard hunkDiscardKey != nil, let tab = window.review else { return }
            await reviewTabHandler?.prepareHunkDiscards(tab)
        }
        // The column's floor is `ReviewInlineSplit`'s, which puts this
        // beside the file list.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
