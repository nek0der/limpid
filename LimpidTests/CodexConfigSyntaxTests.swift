// CodexConfigSyntaxTests.swift
// Limpid — pins how a `config.toml` header or key is read for the name it
// means, and what the check before saving the user's config refuses.

import Testing
@testable import Limpid

@Suite("CodexConfigSyntax")
struct CodexConfigSyntaxTests {
    @Test("reads a header for its name", arguments: [
        ("[a.b.c]", ["a", "b", "c"]),
        ("[ a . \"b\" . 'c' ]", ["a", "b", "c"]),
        ("[a.\"b.c\"]", ["a", "b.c"]),
        ("[\"a#b\"] # note", ["a#b"]),
        ("['a\\n']", ["a\\n"]),
        ("[\"a\\n\\u00e9\\\"\"]", ["a\n\u{e9}\""]),
        ("[\"\"]", [""]),
        ("  [a]\t#", ["a"])
    ])
    func header_wellFormed_readsName(line: String, name: [String]) {
        #expect(CodexConfigSyntax.header(of: line) == .table(.init(name)))
    }

    @Test("reads an array table header")
    func header_arrayTable_readsName() {
        #expect(CodexConfigSyntax.header(of: "[[ a.'b' ]] # x") == .arrayTable(["a", "b"]))
    }

    @Test("refuses a header TOML does not accept", arguments: [
        "[a", "[a.]", "[.a]", "[a b]", "[a] b", "[\"a]", "['a]", "[\"\\q\"]", "[]", "[ [a]]", "[[a]", "[a\u{e9}]",
    ])
    func header_malformed_isMalformed(line: String) {
        #expect(CodexConfigSyntax.header(of: line) == .malformed)
    }

    @Test("is no header for a line that does not open with a bracket", arguments: [
        "a = [1]", "# [a]", "", "  ",
    ])
    func header_notABracket_isNone(line: String) {
        #expect(CodexConfigSyntax.header(of: line) == .none)
    }

    @Test("reads a key for its name", arguments: [
        ("enabled = true", ["enabled"]),
        ("  \"enabled\"=true", ["enabled"]),
        ("a . 'b' = 1", ["a", "b"]),
        ("\"a=b#c\" = 1", ["a=b#c"]),
    ])
    func key_wellFormed_readsName(line: String, name: [String]) {
        #expect(CodexConfigSyntax.key(of: line) == .init(name))
    }

    @Test("is no key for a comment, a header or a value line", arguments: [
        "# a = 1", "[a]", "", "\"x\",", "]",
    ])
    func key_notAKey_isNil(line: String) {
        #expect(CodexConfigSyntax.key(of: line) == nil)
    }

    private func problem(_ text: String) -> CodexConfigSyntax.Problem? {
        CodexUserConfig.problem(in: text)
    }

    @Test("accepts a config that defines each table and key once")
    func problem_validConfig_isNil() {
        #expect(problem("""
        model = "x"
        [a]
        k = 1
        [a.b]
        k = 1
        [[c]]
        k = 1
        [[c]]
        k = 1
        list = [
          [1, 2],
        ]
        notes = '''
        [a]
        k = 1
        '''
        inline = {
          k = 1,
        }
        [fruits]
        apple.color = "red"
        apple.taste = "sweet"
        """) == nil)
    }

    /// Each `[[name]]` element owns its own subtables, so the same
    /// subtable header under two elements defines two tables.
    @Test("accepts the same subtable under two array elements")
    func problem_subtablePerArrayElement_isNil() {
        #expect(problem("[[fruits]]\n[fruits.physical]\nk = 1\n[[fruits]]\n[fruits.physical]\nk = 1\n") == nil)
    }

    @Test("reads a CRLF config as it reads an LF one")
    func problem_crlf_matchesLF() {
        #expect(problem("[a]\r\nk = 1\r\n[b]\r\nk = 1\r\n") == nil)
        #expect(problem("[a]\r\nk = 1\r\n[a] # again\r\n") == .duplicateTable(line: 2))
    }

    /// A key that holds a value, an inline table included, or the table a
    /// dotted key implies, is as defined as a header would make it.
    @Test("finds a header for a name a key already defined", arguments: [
        ("[a]\nb = { x = 1 }\n[a.b]\n", 2),
        ("[a]\nb.c = 1\n[a.b]\n", 2),
        ("a = 1\n[a.b]\n", 1),
        ("hooks = { state = {} }\n[hooks.state.\"x\"]\n", 1)
    ])
    func problem_headerOverKeyDefinedName_isFound(text: String, line: Int) {
        #expect(problem(text) == .duplicateTable(line: line))
    }

    @Test("finds a key for a name already defined")
    func problem_keyOverDefinedName_isFound() {
        #expect(problem("a.b = 1\na = 2\n") == .duplicateKey(line: 1))
        #expect(problem("a = 1\na.b = 2\n") == .duplicateKey(line: 1))
        #expect(problem("[a.b]\n[a]\nb = 1\n") == .duplicateKey(line: 2))
    }

    @Test("finds a table defined twice, however it is written")
    func problem_duplicateTable_isFound() {
        #expect(problem("[a.b]\nk = 1\n[ a . 'b' ] # again\n") == .duplicateTable(line: 2))
        #expect(problem("[[a]]\n[a]\n") == .duplicateTable(line: 1))
        #expect(problem("[a]\n[[a]]\n") == .duplicateTable(line: 1))
    }

    @Test("finds a key set twice in one table")
    func problem_duplicateKey_isFound() {
        #expect(problem("[a]\nk = 1\n\"k\" = 2\n") == .duplicateKey(line: 2))
        #expect(problem("[a]\nk = 1\n[b]\nk = 2\n") == nil)
    }

    /// Swift calls a precomposed `é` and `e` with a combining acute one
    /// string; TOML and Codex's `toml_edit` keep them as two names, so a
    /// config that defines both is valid. Names are compared by scalar.
    @Test("tells canonically equivalent names apart")
    func problem_canonicallyEquivalentNames_areDistinct() {
        #expect("caf\u{E9}" == "cafe\u{301}")
        #expect(CodexConfigSyntax.Name(["caf\u{E9}"]) != CodexConfigSyntax.Name(["cafe\u{301}"]))
        #expect(problem("""
        [projects."/tmp/caf\\u00E9"]
        trust_level = "trusted"
        [projects."/tmp/cafe\\u0301"]
        trust_level = "trusted"
        """) == nil)
        #expect(problem("[t]\n\"caf\u{E9}\" = 1\n\"cafe\u{301}\" = 2\n") == nil)
        #expect(problem("[projects.\"/tmp/caf\\u00E9\"]\n[projects.\"/tmp/caf\u{E9}\"]\n") == .duplicateTable(line: 1))
    }

    @Test("finds a header that does not parse")
    func problem_malformedHeader_isFound() {
        #expect(problem("model = \"x\"\n[a\n") == .malformedHeader(line: 1))
    }
}
