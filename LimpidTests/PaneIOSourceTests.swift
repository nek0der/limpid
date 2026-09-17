// PaneIOSourceTests.swift
// Limpid — pins how a pane's input source persists and how an unknown one degrades.

import Foundation
import Testing
@testable import Limpid

@Suite("Pane IO source")
struct PaneIOSourceTests {
    private func ref() -> TmuxPaneRef {
        TmuxPaneRef(
            binding: TmuxBinding(socketPath: "/tmp/tmux-\(getuid())/default", sessionID: "$3", sessionName: "work"),
            windowID: "@2",
            paneID: "%7"
        )
    }

    @Test("local and tmux sources round-trip through JSON")
    func codec_roundTrips() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for source in [PaneIOSource.local, .tmux(ref()), .unavailable] {
            let data = try encoder.encode(source)
            #expect(try decoder.decode(PaneIOSource.self, from: data) == source)
        }
    }

    @Test("a kind this build does not know decodes as unavailable, never as local")
    func codec_unknownKind_isUnavailable() throws {
        let json = Data(#"{"kind":"ssh","ssh":{"host":"example"}}"#.utf8)
        #expect(try JSONDecoder().decode(PaneIOSource.self, from: json) == .unavailable)
    }

    @Test("a tab without the key has no sources, and every pane reads as local")
    func tab_absentKey_isLocal() throws {
        let (tab, paneID) = Tab.newWithSinglePane(title: "t", container: .loose)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        #expect(object["paneSources"] == nil, "an ordinary tab must not write the key")
        object.removeValue(forKey: "paneSources")
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.paneSources.isEmpty)
        #expect(decoded.ioSource(for: paneID) == .local)
    }

    @Test("a mirror pane's source survives the tab round trip")
    func tab_mirrorSource_roundTrips() throws {
        var (tab, paneID) = Tab.newWithSinglePane(title: "t", container: .loose)
        tab.kind = .tmuxMirror
        tab.paneSources[paneID] = .tmux(ref())
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
        #expect(decoded.kind == .tmuxMirror)
        #expect(decoded.ioSource(for: paneID) == .tmux(ref()))
    }
}
