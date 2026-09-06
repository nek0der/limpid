// TmuxBindingPersistenceTests.swift
// Limpid — pins that a pane's tmux binding survives the round trip it
// exists for, and that adding it does not invalidate a `state.json`
// written before it existed.

import Foundation
import Testing
@testable import Limpid

@Suite("Tab tmux bindings", .tags(.persistence))
struct TmuxBindingPersistenceTests {
    private let pane = UUID()

    private func makeTab() -> Tab {
        Tab(title: "t", splitTree: SplitTree(leafID: UUID()), container: .loose)
    }

    private func binding() -> TmuxBinding {
        TmuxBinding(
            socketPath: "/private/tmp/tmux-501/default",
            sessionID: "$3",
            sessionName: "limpid"
        )
    }

    @Test("a new tab starts with no bindings")
    func tab_new_hasNoBindings() {
        #expect(makeTab().tmuxBindings.isEmpty)
    }

    @Test("survives an encode and decode")
    func tab_withBinding_roundTrips() throws {
        var tab = makeTab()
        tab.tmuxBindings[pane] = binding()
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        #expect(decoded.tmuxBindings[pane] == binding())
    }

    /// The field is additive, so a `state.json` written by a build that
    /// predates it has to keep loading. Encoding a tab, deleting the key
    /// and decoding again is the same shape as that upgrade.
    @Test("decodes a tab written before the field existed")
    func tab_jsonWithoutTheKey_stillDecodes() throws {
        let data = try JSONEncoder().encode(makeTab())
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "tmuxBindings")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Tab.self, from: stripped)
        #expect(decoded.tmuxBindings.isEmpty)
    }
}
