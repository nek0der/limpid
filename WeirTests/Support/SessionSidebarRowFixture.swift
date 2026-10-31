// SessionSidebarRowFixture.swift
// Weir — one sidebar row built from what a test says of it, for the suites about the row, its header, and its dropdown.

import Foundation
@testable import Weir
@testable import WeirDomain

extension SessionSidebarModel.RowInput {
    /// A worktree's row named `name`, there on disk, cut as a name, with nothing to
    /// say beyond `fact`. The rest a test sets on the value.
    static func test(
        container: ContainerID = .worktree(projectID: UUID(), worktreeID: UUID()),
        name: String = "main",
        fact: SessionRowFact.Input = .init(),
        lastActivity: Date? = nil
    ) -> Self {
        .init(container: container, name: name, nameTruncation: .name, fact: fact, lastActivity: lastActivity, isMissing: false)
    }
}

extension SessionSidebarModel.Row {
    /// `input` as the sidebar shows it, alone, while the window is on the
    /// scratch row and no usage limit holds.
    static func test(
        _ input: SessionSidebarModel.RowInput = .test(),
        activeContainer: ContainerID? = .loose,
        shownPanes: Set<UUID> = [],
        locale: Locale = Locale(identifier: "en")
    ) -> Self {
        SessionSidebarModel(
            rows: [input],
            activeContainer: activeContainer,
            shownPanes: shownPanes,
            usageLimits: UsageLimits(items: []),
            locale: locale
        ).rows[0]
    }
}
