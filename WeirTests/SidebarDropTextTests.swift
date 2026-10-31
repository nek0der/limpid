// SidebarDropTextTests.swift
// Weir — what VoiceOver says once a dragged tab or pane lands on a sidebar row.

import Foundation
import Testing
@testable import Weir

@MainActor
struct SidebarDropTextTests {
    typealias Fixture = ProjectWindowsFixture

    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    /// A row of a project is said with its project, since the tab may have
    /// gone to another project than the window's; the scratch row is said
    /// by its own name.
    @Test func moved_namesTheRowAndItsProject() {
        let fixture = Fixture()
        let row = SessionSidebarModel.rowName(of: .project(fixture.b.id), in: fixture.session, locale: Self.english)

        #expect(
            SidebarDropText.moved(isPane: false, to: .project(fixture.b.id), in: fixture.session, locale: Self.english)
                == "Moved the tab to \(row) in b"
        )
        #expect(
            SidebarDropText.moved(isPane: false, to: .project(fixture.b.id), in: fixture.session, locale: Self.japanese)
                == "タブを b の \(row) に移動しました。"
        )
        #expect(SidebarDropText.moved(isPane: false, to: .loose, in: fixture.session, locale: Self.english) == "Moved the tab to Scratch")
        #expect(
            SidebarDropText.moved(isPane: true, to: .project(fixture.b.id), in: fixture.session, locale: Self.japanese)
                == "ペインを b の \(row) に移動しました。"
        )
        #expect(SidebarDropText.moved(isPane: true, to: .loose, in: fixture.session, locale: Self.english) == "Moved the pane to Scratch")
    }
}
