// ScrollingCostMeasurements.swift
// Limpid — the timings of scrolling rows, the shortcut catalog, and the sidebar's list, printed for `make test-measure`.

import Foundation
import Testing
@testable import Limpid

/// The times behind what SupervisionTokensTests, ReviewRailLayoutTests and
/// ResolvedStringCacheTests check, printed for a person to compare before and after a change.
/// Nothing here is checked: the times depend on the machine, which is also
/// why the suite runs only on request (`make test-measure`): a timing a
/// person does not read is noise in CI.
@Suite(.tags(.measurement), .enabled(if: ProcessInfo.processInfo.environment["LIMPID_MEASURE"] == "1"))
struct ScrollingCostMeasurements {
    /// How long `body` takes, in microseconds a run, over `runs` runs.
    private static func microseconds(runs: Int, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<runs {
                body()
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return seconds * 1e6 / Double(runs)
    }

    @Test func aTokensColor() {
        let perAccess = Self.microseconds(runs: 10000) { _ = SupervisionTokens.text.color }
        print("ScrollingCost: ThemedColor.color \(perAccess) µs an access")
    }

    /// The shortcut sheet's catalog, which it builds once a pass.
    @Test func theShortcutCatalog() {
        let keyboard = KeyboardSettings()
        let locale = Locale(identifier: "ja")
        let perBuild = Self.microseconds(runs: 50) {
            _ = KeyboardShortcutCatalog.sections(keyboard: keyboard, quickTerminalHotKey: nil, locale: locale)
        }
        let perQuery = Self.microseconds(runs: 50) {
            _ = KeyboardShortcutCatalog.filter(
                KeyboardShortcutCatalog.sections(keyboard: keyboard, quickTerminalHotKey: nil, locale: locale),
                query: "タブ"
            )
        }
        print("ScrollingCost: shortcut catalog \(perBuild) µs a build, \(perQuery) µs with a query")
    }

    /// The sidebar's list as its body builds it each time it is drawn: ten
    /// projects, `openCount` of them open, one of those with 59 worktrees,
    /// a tab in each made worktree, every row of every project placed in
    /// its section. Ten open is the case where a per-project look over
    /// every tab and item adds up.
    @MainActor
    @Test(arguments: [3, 10])
    func theSidebarsList(openCount: Int) throws {
        let session = WorkspaceSession()
        let projects = (0..<10).map { index in
            session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("p\(index)"), suggestedName: "p\(index)")
        }
        for (index, project) in projects.enumerated() {
            for worktree in 0..<(index == 0 ? 59 : 3) {
                let added = try WorkspaceSessionFixture.appendWorktree(
                    to: project.id,
                    in: session,
                    admission: worktree < 4 ? .created : .discovered
                )
                if worktree < 4 {
                    _ = session.openTab(
                        container: .worktree(projectID: project.id, worktreeID: added.id),
                        in: session.primaryWindowID,
                        intent: .person,
                        selects: false
                    )
                }
            }
        }
        session.primarySelection.projectID = projects[0].id
        session.primarySelection.sidebarArrangement = SidebarArrangement(
            projectOrder: projects.map(\.id),
            collapsedProjects: Set(projects.dropFirst(openCount).map(\.id))
        )
        let window = session.primaryWindowID
        let perBuild = Self.microseconds(runs: 50) {
            let sections = SidebarPresentedSections.computed(
                projectsOf: session,
                window: window,
                windowShowing: { _ in nil },
                queue: AttentionQueue(),
                pullRequest: { _ in nil },
                gitFacts: { _ in nil }
            )
            _ = SidebarListModel(
                session: session,
                window: window,
                sections: sections,
                windowShowing: { _ in nil },
                sources: SidebarListModel.Sources(
                    queue: AttentionQueue(),
                    runtimes: [],
                    approvals: ApprovalLedger(),
                    pullRequest: { _ in nil },
                    gitFacts: { _ in nil },
                    running: { _ in 0 },
                    locale: Locale(identifier: "ja")
                )
            )
        }
        print("ScrollingCost: sidebar list, 10 projects with \(openCount) open and one of 59 worktrees, \(perBuild) µs a build")
    }

    /// One resolve of a localized resource in a given language, which
    /// every row's words, tooltip, and spoken label go through.
    @Test func resolvingAResource() {
        let ja = Locale(identifier: "ja")
        let plain = Self.microseconds(runs: 200) { _ = LocalizedStringResource("Unread").resolved(in: ja) }
        let count = 3
        let interpolated = Self.microseconds(runs: 200) { _ = LocalizedStringResource("\(count) unread").resolved(in: ja) }
        // The launch language's lookup, for comparison only.
        // swiftlint:disable:next launch_language_lookup
        let system = Self.microseconds(runs: 200) { _ = String(localized: "Unread") }
        print("ScrollingCost: resolve \(plain) µs, interpolated \(interpolated) µs, a launch-language lookup \(system) µs")
    }
}
