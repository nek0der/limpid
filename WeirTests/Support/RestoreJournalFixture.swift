// RestoreJournalFixture.swift
// Weir — a restore or discard journal decoded from the JSON the Rust core writes, with each optional key present or left out.

import Foundation
@testable import Weir

enum RestoreJournalFixture {
    /// This is the envelope around a journal's stage. A `nil` field leaves its key
    /// out of the JSON rather than writing a default, because what a test
    /// checks is often how a journal from an older build, one without that
    /// key, is read. `operation` is the raw string, so an operation this
    /// build does not know can be written too.
    struct Fields {
        var opID = "OP"
        var operation: String?
        var root = "/repo"
        var turnID = "T"
        var turnNumber: Int?
        var paneID = "P"
        var undoes: String?
        var at = "2026-10-13T00:00:00Z"
        var ranAt: String?
    }

    /// Decodes a journal whose stage is `stageJSON`, inside the envelope
    /// `fields` describes. The stage is written as is, so a test can also
    /// write a stage this build cannot read.
    static func make(stageJSON: String, fields: Fields = Fields()) throws -> RestoreJournal {
        var members = [
            "\"opId\":\(quoted(fields.opID))",
            "\"root\":\(quoted(fields.root))",
            "\"turnId\":\(quoted(fields.turnID))",
            "\"paneId\":\(quoted(fields.paneID))",
            "\"plannedPaths\":[]",
            "\"stage\":\(stageJSON)",
            "\"at\":\(quoted(fields.at))"
        ]
        if let operation = fields.operation {
            members.append("\"operation\":\(quoted(operation))")
        }
        if let turnNumber = fields.turnNumber {
            members.append("\"turnNumber\":\(turnNumber)")
        }
        if let undoes = fields.undoes {
            members.append("\"undoes\":\(quoted(undoes))")
        }
        if let ranAt = fields.ranAt {
            members.append("\"ranAt\":\(quoted(ranAt))")
        }
        let json = "{\(members.joined(separator: ","))}"
        return try JSONDecoder().decode(RestoreJournal.self, from: Data(json.utf8))
    }

    /// Returns `value` as an escaped JSON string, so a root or an ID with a
    /// quote in it still makes a journal rather than a decoding error. A string
    /// always encodes; the empty fallback only satisfies the type.
    private static func quoted(_ value: String) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
            .flatMap { String(bytes: $0, encoding: .utf8) } ?? "\"\""
    }
}
