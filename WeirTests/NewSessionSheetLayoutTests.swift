// NewSessionSheetLayoutTests.swift
// Weir — the new worktree sheet's words fit it whole, in English and Japanese, and it keeps no empty room.

import AppKit
import SwiftUI
import Testing
@testable import Weir

/// The sheet's segments share the controls' column equally and cut their
/// words rather than grow, and the lines under its controls wrap within
/// two lines, so both are measured against the room the sheet gives them
/// with the longest words each language has. A line is as tall as
/// what it says, and the sheet holds its height while what it waits for
/// comes in.
@MainActor
struct NewSessionSheetLayoutTests {
    private typealias Metrics = WeirLayout.Supervision

    /// Longer than any branch a line shows whole, so the line must cut it.
    private static let longBranch = "nek0der/feature/" + String(repeating: "very-long-branch-name-", count: 8) + "1021-1"

    // MARK: - The segments

    /// Every segment of the source shows its words whole. Three, fixed:
    /// what opens is a menu, which takes any number of agents.
    @Test(arguments: ["en", "ja"])
    func eachSourceSegment_showsItsWordsWhole(language: String) {
        let column = Self.controlColumnWidth(language: language)
        let titles = NewSessionModel.Source.allCases.map { NewSessionSheet.sourceTitle($0) }
        let widths = titles.map { Self.width(of: $0.font(SupervisionSegmentedPicker<Int>.labelFont()), language: language) }
        let needed = SupervisionSegmentedPicker<Int>.minimumWidth(fittingLabelWidths: widths)
        #expect(needed <= column, "\(language): \(needed) in \(column), words \(widths)")
    }

    /// The control's own sum: equal segments, each the widest words and
    /// their padding, inside the track's inset.
    @Test func aSegmentedChoice_needsItsWidestWords_inEverySegment() {
        let padding = Metrics.segmentedHorizontalPadding
        let width = SupervisionSegmentedPicker<Int>.minimumWidth(fittingLabelWidths: [30, 80, 50])
        #expect(width == 3 * (80 + 2 * padding) + 2 * Metrics.segmentedInset)
        let compact = SupervisionSegmentedPicker<Int>.minimumWidth(fittingLabelWidths: [30, 80], isCompact: true)
        #expect(compact == 2 * (80 + 2 * Metrics.spaceS) + 2 * Metrics.segmentedInset)
        #expect(SupervisionSegmentedPicker<Int>.minimumWidth(fittingLabelWidths: []) == 2 * Metrics.segmentedInset)
    }

    // MARK: - The lines under the controls

    /// What Create will do, said in the longest form each language has and
    /// naming branches far longer than a line shows: the sentence wraps
    /// within the two lines the sheet keeps, and the cut falls in the
    /// branch, never in the words around it.
    @Test(arguments: ["en", "ja"])
    func theLineUnderTheBranch_wrapsWithinItsTwoLines(language: String) {
        let locale = Locale(identifier: language)
        let column = Self.controlColumnWidth(language: language)
        let outcomes: [NewSessionModel.Outcome] = [
            .newBranch(Self.longBranch, base: "origin/" + Self.longBranch),
            .existingBranch(Self.longBranch),
            .pullRequest(number: 99999, branch: Self.longBranch, isExisting: false),
            .pullRequest(number: 99999, branch: Self.longBranch, isExisting: true)
        ]
        let reserved = Self.twoLineHeight(language: language)
        for outcome in outcomes {
            let runs = NewSessionModel.resultRuns(outcome, locale: locale)
            let line = NewSessionStatusLine(runs: runs, color: .primary, lineLimit: nil)
            let height = Self.height(of: line, width: column, language: language)
            #expect(height <= reserved, "\(language) \(outcome): \(height) in \(reserved)")
        }
    }

    /// A problem that names the typed branch wraps within the same lines,
    /// the name cut before the sentence is laid out.
    @Test(arguments: ["en", "ja"])
    func aProblemNamingALongBranch_wrapsWithinItsTwoLines(language: String) throws {
        let locale = Locale(identifier: language)
        var model = Self.model(branches: ["main", Self.longBranch])
        model.setBranchName(Self.longBranch)
        guard case let .problem(problem) = model.branchLine else {
            Issue.record("a typed name that is a branch says so: \(model.branchLine)")
            return
        }
        let text = try #require(NewSessionProblemText.text(problem, model: model, locale: locale))
        #expect(!text.contains(Self.longBranch), "the name is cut before the line is laid out")
        let column = Self.controlColumnWidth(language: language)
        let line = NewSessionStatusLine(runs: [.plain(text)], color: .primary, lineLimit: nil)
        #expect(Self.height(of: line, width: column, language: language) <= Self.twoLineHeight(language: language), "\(text)")
    }

    // MARK: - The whole sheet

    /// The sheet is its own width in either language, and as tall as it
    /// opened while what it waits for comes in (the fetch's answer, the
    /// carry's count) and while a choice changes no line, so nothing moves
    /// it under the pointer (macOS keeps a sheet centered on its window).
    @Test(arguments: ["en", "ja"])
    func theSheet_keepsItsSize_asWhatItWaitsForArrives(language: String) throws {
        try withTempDir { directory in
            var sizes: [(String, CGSize)] = []
            for (name, edit) in Self.arrivals {
                var model = Self.model(branches: ["main", "release/2026-10"])
                edit(&model)
                sizes.append((name, Self.sheetSize(model, language: language, directory: directory)))
            }
            let first = try #require(sizes.first?.1)
            #expect(first.width == Metrics.newSessionSheetWidth, "\(language): \(first)")
            for (name, size) in sizes {
                #expect(size == first, "\(language) \(name): \(size), not \(first)")
            }
        }
    }

    /// A pull request's answer comes over the network after its number is
    /// typed: the sheet is as tall while it is looked up as once it is
    /// found, under a long branch, a long title, and a fork, or not.
    @Test(arguments: ["en", "ja"])
    func theSheet_keepsItsSize_asAPullRequestsAnswerArrives(language: String) throws {
        try withTempDir { directory in
            var typed = Self.model(branches: ["main"])
            typed.source = .pullRequest
            typed.setPullRequestText("12")
            #expect(typed.awaitsPullRequestAnswer)
            var found = typed
            let head = PullRequestHead(
                number: 12,
                title: "Keep the invoice total when a discount and a credit note meet on one line of the same invoice",
                state: .closed,
                headBranch: Self.longBranch,
                headCommit: nil,
                forkOwner: "alice"
            )
            found.setPullRequestLookup(.found(head), for: 12)
            var missing = typed
            missing.setPullRequestLookup(.notFound(12), for: 12)
            let size = Self.sheetSize(typed, language: language, directory: directory)
            #expect(Self.sheetSize(found, language: language, directory: directory) == size, "\(language) found")
            #expect(Self.sheetSize(missing, language: language, directory: directory) == size, "\(language) not found")
        }
    }

    /// A line that says nothing keeps no room: with a local base, which no
    /// fetch changes, the sheet is shorter by the line under the base and
    /// the gap above it, and no more.
    @Test(arguments: ["en", "ja"])
    func theSheet_keepsNoRoomForTheBaseLine_whileItSaysNothing(language: String) throws {
        try withTempDir { directory in
            var fetching = Self.model(branches: ["main"])
            fetching.fetchState = .fetching
            var local = Self.model(branches: ["main"])
            local.fetches = false
            #expect(local.baseLine == nil)
            let withLine = Self.sheetSize(fetching, language: language, directory: directory).height
            let without = Self.sheetSize(local, language: language, directory: directory).height
            let oneLine = Self.lineHeight(lines: 1, language: language)
            let room = withLine - without
            #expect(room >= oneLine, "\(language): \(room)")
            #expect(room <= oneLine + Metrics.newSessionInlineSpacing + 1, "\(language): \(room), one line \(oneLine)")
        }
    }

    /// The line under the branch is one line when its sentence is: a branch
    /// of the length the sheet suggests, from a usual base, in either
    /// language. Nothing under it is kept for a second line.
    @Test(arguments: ["en", "ja"])
    func theLineUnderTheBranch_takesOneLine_forAUsualName(language: String) {
        let locale = Locale(identifier: language)
        let column = Self.controlColumnWidth(language: language)
        let oneLine = Self.lineHeight(lines: 1, language: language)
        let outcomes: [NewSessionModel.Outcome] = [
            .newBranch("task/1021-3", base: "master"),
            .newBranch("task/1021-3", base: "origin/main"),
            .existingBranch("release/2026-10")
        ]
        for outcome in outcomes {
            let line = NewSessionStatusLine(runs: NewSessionModel.resultRuns(outcome, locale: locale), color: .primary, lineLimit: nil)
            let height = Self.height(of: line, width: column, language: language)
            #expect(abs(height - oneLine) <= 1, "\(language) \(outcome): \(height), one line \(oneLine)")
        }
    }

    /// The longest name the line shows grows the sheet by exactly the
    /// line it adds: by its second line where the sentence wraps (English),
    /// by nothing where it still fits one (Japanese, whose labels leave the
    /// column wider).
    @Test(arguments: ["en", "ja"])
    func theSheet_growsByTheLineTheLongestNameAdds(language: String) throws {
        try withTempDir { directory in
            let short = Self.model(branches: ["main"])
            var long = Self.model(branches: ["main"])
            long.setBranchName(Self.longBranch)
            let grown = Self.sheetSize(long, language: language, directory: directory).height
                - Self.sheetSize(short, language: language, directory: directory).height
            let oneLine = Self.lineHeight(lines: 1, language: language)
            let secondLine = Self.lineHeight(lines: 2, language: language) - oneLine
            guard case let .outcome(outcome) = long.branchLine else {
                Issue.record("a long new name says what Create will do: \(long.branchLine)")
                return
            }
            let line = NewSessionStatusLine(
                runs: NewSessionModel.resultRuns(outcome, locale: Locale(identifier: language)),
                color: .primary,
                lineLimit: nil
            )
            let wraps = Self.height(of: line, width: Self.controlColumnWidth(language: language), language: language) > oneLine + 1
            #expect(abs(grown - (wraps ? secondLine : 0)) <= 1, "\(language): grew \(grown), wraps \(wraps)")
            if language == "en" {
                #expect(wraps, "the longest name takes the English line's second line")
            }
        }
    }

    /// The carry's line keeps the room of its longest form from the
    /// start: every form it can take is offered, the one it says now among
    /// them, each once; with no worktree to carry from there is only one.
    @Test func theCarryLine_offersEveryFormItCanTake() {
        let english = Locale(identifier: "en")
        var model = Self.model(branches: ["main"])
        let forms = model.carryLineForms(locale: english)
        #expect(forms.count == 3)
        #expect(Set(forms).count == forms.count)
        #expect(forms.contains(model.carryLine(locale: english)))
        model.setCarryCount(4)
        #expect(model.carryLineForms(locale: english) == forms, "the forms do not follow the count")
        let (_, project) = WorkspaceSessionFixture.withProject(name: "duesmith")
        var context = Self.context(project: project, branches: ["main"])
        context.carrySource = nil
        let alone = NewSessionModel(
            context: context,
            choices: NewWorktreeChoices(open: .nothing, fetches: false, copiesIgnoredFiles: false, runsSetup: false)
        )
        #expect(alone.carryLineForms(locale: english) == [alone.carryLine(locale: english)])
    }

    /// What the size test lets arrive, or chooses without changing a line,
    /// by name: the sheet's first frame, before its fetch starts, first.
    private static let arrivals: [(String, (inout NewSessionModel) -> Void)] = [
        ("opened, the fetch not started", { _ in }),
        ("fetching", { $0.fetchState = .fetching }),
        ("fetched, up to date", { $0.fetchState = .fetched(behind: 0) }),
        ("fetched, far behind", { $0.fetchState = .fetched(behind: 1234) }),
        ("fetched, no such branch on the remote", { $0.fetchState = .remoteBranchMissing }),
        ("carry counted", { model in
            model.fetchState = .fetching
            model.setCarryCount(12)
        }),
        ("carry counted, none", { model in
            model.fetchState = .fetching
            model.setCarryCount(0)
        }),
        ("nothing opens", { model in
            model.fetchState = .fetching
            model.open = .nothing
        }),
        ("Codex opens", { model in
            model.fetchState = .fetching
            model.open = .agent(.codex)
        })
    ]

    // MARK: - Measuring

    /// The room the sheet leaves its controls: its width inside its insets,
    /// less the labels' column (its widest label) and the gap after it.
    /// The labels are measured in the language asked for, not in the
    /// development one: the Japanese column is narrower than the English.
    @Test func theLabelsColumn_isMeasuredInEachLanguage() {
        #expect(Self.controlColumnWidth(language: "ja") != Self.controlColumnWidth(language: "en"))
    }

    private static func controlColumnWidth(language: String) -> CGFloat {
        let insets = Metrics.newSessionSheetInsets
        let labels = NewSessionSheet.rowLabels.map {
            width(of: Text($0).font(.supervision(Metrics.sheetLabelFontSize)), language: language)
        }
        return Metrics.newSessionSheetWidth - insets.leading - insets.trailing
            - (labels.max() ?? 0) - Metrics.newSessionColumnSpacing
    }

    private static func width(of text: some View, language: String) -> CGFloat {
        NSHostingController(rootView: text.fixedSize().environment(\.locale, Locale(identifier: language)))
            .sizeThatFits(in: CGSize(width: 4000, height: 200)).width
    }

    private static func height(of view: some View, width: CGFloat, language: String) -> CGFloat {
        NSHostingController(rootView: view.frame(width: width).environment(\.locale, Locale(identifier: language)))
            .sizeThatFits(in: CGSize(width: width, height: 4000)).height
    }

    /// The most a line under a control takes: two lines of the line font.
    private static func twoLineHeight(language: String) -> CGFloat {
        lineHeight(lines: NewSessionStatusLine.lineCount, language: language)
    }

    /// `lines` lines of the line font, drawn as a line is.
    private static func lineHeight(lines: Int, language: String) -> CGFloat {
        height(of: NewSessionStatusLine.reservedSpace(lines: lines), width: 200, language: language)
    }

    private static func sheetSize(_ model: NewSessionModel, language: String, directory: URL) -> CGSize {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "duesmith")
        var model = model
        model.setProject(project)
        let sheet = NewSessionSheet(request: NewSessionSheetRequest(projectID: project.id), model: model)
            .environment(session)
            .environment(SessionLaunchStore(path: { nil }, git: FakeGit()))
            .environment(ProjectWindowState(selection: session.primarySelection))
            .environment(SettingsStore(directory: directory, writesFiles: false))
            .environment(\.locale, Locale(identifier: language))
        return NSHostingView(rootView: sheet).fittingSize
    }

    private static func model(branches: [String]) -> NewSessionModel {
        let (_, project) = WorkspaceSessionFixture.withProject(name: "duesmith")
        return NewSessionModel(
            context: Self.context(project: project, branches: branches),
            choices: NewWorktreeChoices(open: .agent(.claude), fetches: true, copiesIgnoredFiles: true, runsSetup: true)
        )
    }

    /// A project with a remote, Claude and Codex found, and the shown
    /// worktree's changes to carry, under a long branch.
    private static func context(project: Project, branches: [String]) -> NewSessionModel.Context {
        var context = NewSessionModel.Context(
            project: project,
            localBranches: branches,
            checkedOutBranches: [],
            defaultBase: "main",
            shownBranch: nil,
            head: "main",
            fetchRemote: "origin",
            today: Date(timeIntervalSince1970: 1_792_540_800),
            installedAgents: [.claude, .codex],
            folderExists: { _ in false }
        )
        context.carrySource = .init(root: URL(fileURLWithPath: "/tmp/duesmith-carry"), name: longBranch)
        return context
    }
}
