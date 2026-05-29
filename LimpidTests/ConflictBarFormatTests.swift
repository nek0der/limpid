// ConflictBarFormatTests.swift
// Limpid — the party bar's format selection (spec §8.x). Pure and
// locale-independent: it picks WHICH one-liner shape to show; the
// localized text is produced separately in the view.

import Foundation
import Testing
@testable import Limpid

@Suite("ConflictBar format selection")
struct ConflictBarFormatTests {

    @Test("one opponent, one file → names the file (basename only)")
    func format_oneOpponentOneFile() {
        let format = ConflictBarSummary.format(
            opponents: ["payment"], fileCount: 1, threshold: 1, firstFile: "src/middleware.ts"
        )
        #expect(format == .oneFile(opponent: "payment", file: "middleware.ts"))
    }

    @Test("one opponent, files over threshold → collapses to a count")
    func format_oneOpponentManyFiles() {
        let format = ConflictBarSummary.format(
            opponents: ["payment"], fileCount: 30, threshold: 1, firstFile: "a.ts"
        )
        #expect(format == .manyFiles(opponent: "payment", count: 30))
    }

    @Test("multiple opponents → lists them")
    func format_multipleOpponents() {
        let format = ConflictBarSummary.format(
            opponents: ["payment", "settings"], fileCount: 3, threshold: 1, firstFile: "a.ts"
        )
        #expect(format == .manyOpponents(joined: "payment, settings"))
    }

    @Test("more than two opponents fold into a +N suffix")
    func format_manyOpponents_foldsExtra() {
        let format = ConflictBarSummary.format(
            opponents: ["a", "b", "c", "d"], fileCount: 1, threshold: 1, firstFile: nil
        )
        #expect(format == .manyOpponents(joined: "a, b, +2"))
    }

    @Test("no opponents → no bar")
    func format_noOpponents_isNil() {
        #expect(ConflictBarSummary.format(opponents: [], fileCount: 1, threshold: 1, firstFile: "a") == nil)
    }

    @Test("a higher threshold keeps file naming for small overlaps")
    func format_thresholdRespected() {
        // 3 files, threshold 5 → still under, so name the first file.
        let format = ConflictBarSummary.format(
            opponents: ["payment"], fileCount: 3, threshold: 5, firstFile: "x/y.swift"
        )
        #expect(format == .oneFile(opponent: "payment", file: "y.swift"))
    }
}
