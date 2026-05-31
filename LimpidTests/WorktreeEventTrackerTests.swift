// WorktreeEventTrackerTests.swift
// Limpid — Pure-function tests for the watcher's filename filter.
// The directory watch itself is fs-event-driven and not amenable to
// deterministic unit testing; what we *can* lock down is the rule
// that decides which entries get consumed.

import Foundation
import Testing
@testable import Limpid

struct WorktreeEventTrackerTests {
    @Test
    func freshEventFilenames_skipsTmpRenamePartials() {
        // The hook writes `<name>.tmp` then atomically renames to
        // `<name>`. The watcher must ignore the `.tmp` partial — if
        // it consumed and deleted the half-flushed tempfile we'd
        // race the rename and lose every event silently.
        let names = [
            "1780269648-12345-create.json",
            "1780269648-12345-create.json.tmp"
        ]
        let fresh = WorktreeEventTracker.freshEventFilenames(in: names, seen: [])
        #expect(fresh == ["1780269648-12345-create.json"])
    }

    @Test
    func freshEventFilenames_skipsAlreadySeen() {
        let names = ["a-create.json", "b-create.json"]
        let fresh = WorktreeEventTracker.freshEventFilenames(
            in: names, seen: ["a-create.json"]
        )
        #expect(fresh == ["b-create.json"])
    }

    @Test
    func freshEventFilenames_sortsByName() {
        // Sorting by filename means events within one fs burst
        // process in their ns-timestamp embedded order rather than
        // arbitrary directory-listing order.
        let names = [
            "b-create.json",
            "c-create.json",
            "a-create.json"
        ]
        let fresh = WorktreeEventTracker.freshEventFilenames(in: names, seen: [])
        #expect(fresh == ["a-create.json", "b-create.json", "c-create.json"])
    }
}
