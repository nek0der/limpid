// HighImpactCommand.swift
// Weir — the commands too far-reaching to allow without the full context.

import Foundation

/// The commands whose effect is wide or hard to undo: a recursive
/// remove, a forced push, a hard reset, a forced clean, anything under
/// sudo, dd given an input file (`if=`), as it is when it overwrites a
/// device, making a file system, and making a tree world-writable. The menu bar never offers to allow one; the person
/// answers it in Weir, where the card shows its context.
///
/// Erring on the side of caution is the point: a command that only looks
/// like one of these is still sent to Weir, never allowed from the menu.
/// So the line is not parsed as a shell would. It is cut at every operator
/// and grouping (`;`, `&`, `|`, parentheses, braces, substitutions), its
/// words lose their quotes and backslashes and are lowercased (the file
/// system ignores case by default), and every word of each piece is tried
/// as the start of a command. That catches one hidden behind another
/// (`make && rm -rf x`), behind a wrapper (`env`, `xargs`, `nohup`,
/// `bash -c`), inside `if … then`, or spelled `\rm`; a word that only
/// mentions one (`echo sudo`) is caught as well, which costs a trip to
/// Weir and nothing more. Long options are matched by the shortest
/// prefix the tools accept (`git reset --har`, GNU `rm --rec`).
///
/// It is a list, not a shell: it cannot see through an ANSI-C quote
/// (`$'\x72m'`), a glob (`/bin/r?`), a variable (`c=rm; $c -rf x`), or an
/// alias. What guards the menu is that it allows only a command it shows
/// whole, on one line, with nothing hidden (`MenuBarApprovalRule`), so the
/// person reads what runs; this list keeps the plainly dangerous ones off
/// it even then. A line holding `$'` anywhere is taken as high-impact
/// outright, since that costs only a trip to Weir.
enum HighImpactCommand {
    static func isHighImpact(_ commandLine: String) -> Bool {
        if commandLine.contains("$'") {
            return true
        }
        return commands(in: commandLine).contains { words in
            words.indices.contains { isHighImpact(words: words[$0...]) }
        }
    }

    /// The line cut into pieces at its operators and groupings, each as its
    /// words with quotes and backslashes removed and lowercased.
    static func commands(in line: String) -> [[String]] {
        var separated = line
        for separator in ["$(", "&&", "||", ";", "&", "|", "(", ")", "{", "}", "`", "\n", "\r"] {
            separated = separated.replacingOccurrences(of: separator, with: "\u{1F}")
        }
        return separated.split(separator: "\u{1F}").map { piece in
            piece.split(whereSeparator: \.isWhitespace).map(normalized).filter { !$0.isEmpty }
        }
    }

    /// A word as the shell would hand it over, near enough: without quotes
    /// or escaping backslashes, and lowercased.
    private static func normalized(_ word: Substring) -> String {
        String(word.filter { !["\"", "'", "\\"].contains($0) }).lowercased()
    }

    private static func isHighImpact(words: ArraySlice<String>) -> Bool {
        guard let first = words.first else { return false }
        let program = programName(first)
        let arguments = words.dropFirst()
        switch program {
        case "sudo":
            return true
        case "rm":
            return arguments.contains { isFlag($0, containing: ["r"]) || abbreviates($0, "--recursive") }
        case "git":
            return isHighImpactGit(arguments)
        case "dd":
            return arguments.contains { $0.hasPrefix("if=") }
        case "chmod":
            return arguments.contains { isFlag($0, containing: ["r"]) || abbreviates($0, "--recursive") }
                && arguments.contains(where: isWorldWritable)
        default:
            return program == "mkfs" || program.hasPrefix("mkfs.")
        }
    }

    /// `git push --force` (or `-f`, `--force-with-lease`, `+refspec`), `git
    /// reset --hard`, and `git clean -f`, wherever the option stands. The
    /// subcommand is looked for among the words rather than taken as the
    /// first that is not an option, since the options before it may take
    /// a value (`git --namespace foo push`).
    private static func isHighImpactGit(_ arguments: ArraySlice<String>) -> Bool {
        arguments.indices.contains { index in
            let options = arguments[(index + 1)...]
            switch arguments[index] {
            case "push":
                return options.contains {
                    $0.hasPrefix("--force") || abbreviates($0, "--force") || isFlag($0, containing: ["f"]) || $0.hasPrefix("+")
                }
            case "reset":
                return options.contains { abbreviates($0, "--hard") }
            case "clean":
                return options.contains { abbreviates($0, "--force") || isFlag($0, containing: ["f"]) }
            default:
                return false
            }
        }
    }

    /// Whether `word` is `option` or a prefix of it the tools accept: git
    /// and GNU getopt take any unambiguous one, down to `rm --r`, so any
    /// prefix past the dashes counts, ambiguous or not.
    private static func abbreviates(_ word: String, _ option: String) -> Bool {
        word.count >= 3 && option.hasPrefix(word)
    }

    /// A mode that lets others write: an octal mode whose last digit has the
    /// write bit (`777`, `0777`, `666`), or a symbolic one granting `w` to
    /// all or to others (`a+rwx`, `o+w`, `+w`).
    private static func isWorldWritable(_ mode: String) -> Bool {
        // Octal of any length: the last digit is for others (`77` is `077`).
        if let last = mode.last, mode.allSatisfy({ ("0"..."7").contains($0) }) {
            return ["2", "3", "6", "7"].contains(last)
        }
        return mode.split(separator: ",").contains { clause in
            guard let operatorIndex = clause.firstIndex(where: { $0 == "+" || $0 == "=" }) else { return false }
            let who = clause[..<operatorIndex]
            let permissions = clause[clause.index(after: operatorIndex)...]
            return permissions.contains("w") && (who.isEmpty || who.contains("a") || who.contains("o"))
        }
    }

    /// Whether `word` is a short-option cluster (`-rf`) holding one of
    /// `letters` (lowercase, as the words are).
    private static func isFlag(_ word: String, containing letters: Set<Character>) -> Bool {
        guard word.hasPrefix("-"), !word.hasPrefix("--"), word.count > 1 else { return false }
        return word.dropFirst().contains(where: letters.contains)
    }

    /// The program a word names, without its directory (`/bin/rm`).
    private static func programName(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }
}
