//! Which shell commands count as a turn's check: the tests or builds the
//! agent ran to see whether its change works. The decision bar shows the last
//! one's result, so the rules here decide what a person is told was checked.
//!
//! A command counts when one of its simple commands starts with a pattern's
//! words, after any `NAME=value` and a wrapper such as `timeout 600` or
//! `uv run`. A pattern's last word may end in `*` (`make test*`). The project
//! may replace the defaults; an empty list turns checks off.
//!
//! This reads what an agent types, not every shell: quotes, escapes, line
//! continuations, comments, the separators, redirections, here-documents,
//! subshells, and command substitutions. Where it cannot tell, it says less:
//! a check whose exit status may be another command's gets no ✓ or ✗.

/// The patterns a project gets until it sets its own.
pub const DEFAULT_CHECK_PATTERNS: &[&str] = &[
    "make test*",
    "npm test",
    "pnpm test",
    "cargo test",
    "swift test",
    "pytest",
    "go test",
];

/// A command that counts as a check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CheckRun {
    /// The command as the agent ran it, so the person sees what was run.
    pub command: String,
    /// Whether the run was narrowed to part of the suite (`FILTER=`,
    /// `--filter`, a path or a name): a success then says nothing about the
    /// rest, and the interface says "filtered".
    pub is_filtered: bool,
    /// Whether the whole command's exit status is the check's own: it is the
    /// last simple command, runs in the foreground, is not piped on, does not
    /// run only when something before it failed (`||`), and is not inside a
    /// command substitution or an `if`, loop, or `case`. Otherwise (`cargo test 2>&1 | tail`,
    /// `make test || true`, `make test &`) the status belongs to something
    /// else, and no ✓ or ✗ may be shown. After `&&` it is kept: a failure
    /// there can be the earlier command's, but then the agent's own run did
    /// not pass either.
    pub is_exit_its_own: bool,
}

/// Whether `command` is a check under `patterns`, and how it ran.
#[must_use]
pub fn classify<S: AsRef<str>>(command: &str, patterns: &[S]) -> Option<CheckRun> {
    let patterns: Vec<Vec<&str>> = patterns
        .iter()
        .map(|pattern| pattern.as_ref().split_whitespace().collect::<Vec<_>>())
        .filter(|words| !words.is_empty())
        .collect();
    let segments = simple_commands(command);
    let last = segments.len().checked_sub(1)?;
    // The last match is the one whose status can be the command's.
    segments
        .iter()
        .enumerate()
        .rev()
        .find_map(|(index, segment)| {
            let (mut assignments, words) = split_assignments(&segment.words);
            let unwrapped = unwrap(words);
            assignments.extend(unwrapped.assignments);
            let words = tool_words(unwrapped.words);
            patterns.iter().find_map(|pattern| {
                if !matches(pattern, &words) {
                    return None;
                }
                let rest = &words[pattern.len()..];
                Some(CheckRun {
                    command: command.trim().to_owned(),
                    is_filtered: assignments.iter().any(|name| narrows(name))
                        || narrows_arguments(rest),
                    // `!` inverts the status, so it is not the check's.
                    is_exit_its_own: index == last
                        && !segment.is_followed
                        && !segment.may_not_run
                        && !segment.is_substituted
                        && !unwrapped.is_negated,
                })
            })
        })
}

/// One simple command and where it sits on the line.
#[derive(Default)]
struct Segment {
    words: Vec<String>,
    /// Piped on, or joined to more by `&&`, `||`, or `&` (the background).
    is_followed: bool,
    /// This is true when it may not have run, so the line's status may be
    /// another command's: it runs only when the command before it failed
    /// (`a || b`), sits in a later branch, or is inside an `if`, `while`,
    /// `until`, `for`, `select`, or `case` (or its condition). `if false;
    /// then make test; fi` exits 0 without running the test.
    may_not_run: bool,
    /// Inside `$(…)` or backquotes: its status is not the line's.
    is_substituted: bool,
}

/// What the next word of a line is.
#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum NextWord {
    /// A word of the command.
    #[default]
    Argument,
    /// The target of a redirection, which is not an argument.
    RedirectTarget,
    /// The word that ends a here-document; `true` for `<<-`, whose body
    /// may indent it with tabs.
    Delimiter(bool),
}

/// How a command substitution was opened, which decides what closes it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Opening {
    /// `$(`: closed by the `)` that matches it.
    Dollar,
    /// A backquote: closed by the next one.
    Backquote,
}

/// The reader's state around an open command substitution, put back when
/// it closes: the command it is part of, the word it sits in, and whether
/// that word was quoted.
struct Frame {
    opening: Opening,
    /// Subshell parentheses open inside a `$(`, so their `)` does not close it.
    depth: usize,
    current: Segment,
    word: String,
    next_word: NextWord,
    quote: Option<char>,
    next_follows_or: bool,
}

type Chars<'a> = std::iter::Peekable<std::str::Chars<'a>>;

/// The state of `simple_commands` while it reads a line.
#[derive(Default)]
struct Reader {
    segments: Vec<Segment>,
    current: Segment,
    word: String,
    /// Whether the current word has started (an empty quoted word has).
    has_word: bool,
    next_word: NextWord,
    /// The quote the reader is inside, if any.
    quote: Option<char>,
    /// Here-documents whose bodies start at the next newline, with whether
    /// each strips leading tabs.
    delimiters: Vec<(String, bool)>,
    /// Each open substitution, innermost last.
    frames: Vec<Frame>,
    /// Whether the next command runs after `||`.
    next_follows_or: bool,
    /// Set once the line has entered another branch (`else`, `elif`, a
    /// `case` arm after `;;`): which branch ran is not known, so no later
    /// command's status is the check's.
    is_branched: bool,
    /// This counts how many `if`, loop, and `case` commands are open around
    /// the reader.
    conditional_depth: usize,
}

/// Words that close a compound command (`{ …; }`, `if …; fi`) and run
/// nothing themselves.
const CLOSERS: &[&str] = &["}", "fi", "done", "esac"];

/// These words open a command whose body may run once, many times, or not
/// at all. Each is closed by `fi`, `done`, or `esac`.
const CONDITIONAL_OPENERS: &[&str] = &["if", "while", "until", "for", "select", "case"];

/// These words may stand before an opener at the start of a command
/// (`then if …`, `! while …`) without opening anything themselves.
const OPENER_PREFIXES: &[&str] = &["{", "!", "then", "do", "else", "elif"];

impl Reader {
    fn push(&mut self, character: char) {
        self.word.push(character);
        self.has_word = true;
    }

    fn finish_word(&mut self) {
        if !self.has_word {
            return;
        }
        self.has_word = false;
        let word = std::mem::take(&mut self.word);
        match std::mem::take(&mut self.next_word) {
            NextWord::Argument => self.current.words.push(word),
            NextWord::RedirectTarget => {}
            NextWord::Delimiter(strips_tabs) => self.delimiters.push((word, strips_tabs)),
        }
    }

    /// Ends the current command. `is_followed` says whether a separator
    /// that joins it to more came after it.
    fn finish_segment(&mut self, is_followed: bool) {
        self.finish_word();
        let is_substituted = !self.frames.is_empty();
        let closes_only = self
            .current
            .words
            .iter()
            .all(|word| CLOSERS.contains(&word.as_str()));
        if closes_only {
            let closed = self
                .current
                .words
                .iter()
                .filter(|word| matches!(word.as_str(), "fi" | "done" | "esac"))
                .count();
            self.conditional_depth = self.conditional_depth.saturating_sub(closed);
            self.current.words.clear();
            // A separator after a parenthesis or a closing word, as in
            // `(npm test) | tail`, belongs to the command it closed.
            if is_followed && let Some(previous) = self.segments.last_mut() {
                previous.is_followed = true;
            }
            return;
        }
        if self
            .current
            .words
            .first()
            .is_some_and(|word| matches!(word.as_str(), "else" | "elif"))
        {
            self.is_branched = true;
        }
        // The opener's own condition is inside it too: `if make test; then
        // …` exits with the branch's status, not the test's.
        let opened = self
            .current
            .words
            .iter()
            .take_while(|word| {
                CONDITIONAL_OPENERS.contains(&word.as_str())
                    || OPENER_PREFIXES.contains(&word.as_str())
            })
            .filter(|word| CONDITIONAL_OPENERS.contains(&word.as_str()))
            .count();
        self.conditional_depth += opened;
        let mut segment = std::mem::take(&mut self.current);
        segment.is_followed = is_followed;
        segment.may_not_run = std::mem::take(&mut self.next_follows_or)
            || self.is_branched
            || self.conditional_depth > 0;
        segment.is_substituted = is_substituted;
        self.segments.push(segment);
    }

    fn open_substitution(&mut self, opening: Opening) {
        // The word the substitution sits in goes on when it closes; inside
        // it, words start afresh.
        self.has_word = false;
        self.frames.push(Frame {
            opening,
            depth: 0,
            current: std::mem::take(&mut self.current),
            word: std::mem::take(&mut self.word),
            next_word: std::mem::take(&mut self.next_word),
            quote: self.quote.take(),
            next_follows_or: std::mem::take(&mut self.next_follows_or),
        });
    }

    /// Closes the innermost substitution and puts back what surrounded it;
    /// the word that held it goes on, with the substitution standing for
    /// one opaque value.
    fn close_substitution(&mut self) {
        self.finish_segment(false);
        if let Some(frame) = self.frames.pop() {
            self.current = frame.current;
            self.word = frame.word;
            self.word.push_str("$()");
            self.has_word = true;
            self.next_word = frame.next_word;
            self.quote = frame.quote;
            self.next_follows_or = frame.next_follows_or;
        }
    }

    /// `$((…))`: arithmetic, read past as one opaque value. Its `<<` is a
    /// shift, not a here-document.
    fn skip_arithmetic(&mut self, chars: &mut Chars<'_>) {
        let mut depth = 2;
        for next in chars.by_ref() {
            match next {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                _ => {}
            }
        }
        self.word.push_str("$(())");
        self.has_word = true;
    }

    /// A redirection operator starting with `character` (`>`, `<`): the
    /// word after it is its target, or a here-document's delimiter.
    fn redirect(&mut self, character: char, chars: &mut Chars<'_>) {
        // A file descriptor written before the operator (`2>`).
        if self.has_word && self.word.chars().all(|c| c.is_ascii_digit()) {
            self.word.clear();
            self.has_word = false;
        } else {
            self.finish_word();
        }
        let is_heredoc = character == '<' && chars.peek() == Some(&'<') && {
            let mut ahead = chars.clone();
            ahead.next();
            ahead.peek() != Some(&'<')
        };
        while matches!(chars.peek(), Some('>' | '<' | '&' | '|')) {
            chars.next();
        }
        self.next_word = if is_heredoc {
            let strips_tabs = chars.peek() == Some(&'-');
            if strips_tabs {
                chars.next();
            }
            NextWord::Delimiter(strips_tabs)
        } else {
            NextWord::RedirectTarget
        };
    }

    /// Skips the bodies of the here-documents opened on the line that just
    /// ended: text, not commands. A body ends at a line that is exactly its
    /// delimiter (after leading tabs, for `<<-`).
    fn skip_here_documents(&mut self, chars: &mut Chars<'_>) {
        for (delimiter, strips_tabs) in std::mem::take(&mut self.delimiters) {
            let mut line = String::new();
            for next in chars.by_ref() {
                if next != '\n' {
                    line.push(next);
                    continue;
                }
                let content = if strips_tabs {
                    line.trim_start_matches('\t')
                } else {
                    line.as_str()
                };
                if content == delimiter {
                    break;
                }
                line.clear();
            }
        }
    }

    /// `|`, `||`, `&`, or `&&`: the command before it is followed.
    fn join(&mut self, character: char, chars: &mut Chars<'_>) {
        let is_doubled = chars.peek() == Some(&character);
        if is_doubled {
            chars.next();
        }
        self.finish_segment(true);
        if character == '|' && is_doubled {
            self.next_follows_or = true;
        }
    }

    /// `(` outside quotes: a subshell, and inside a `$(` one more `)` to
    /// match before it closes.
    fn open_parenthesis(&mut self) {
        if let Some(frame) = self.frames.last_mut()
            && frame.opening == Opening::Dollar
        {
            frame.depth += 1;
        }
        self.finish_segment(false);
    }

    /// `)` outside quotes: closes a subshell, or the `$(` it matches.
    fn close_parenthesis(&mut self) {
        match self.frames.last_mut() {
            Some(frame) if frame.opening == Opening::Dollar && frame.depth == 0 => {
                self.close_substitution();
            }
            Some(frame) if frame.opening == Opening::Dollar => {
                frame.depth -= 1;
                self.finish_segment(false);
            }
            _ => self.finish_segment(false),
        }
    }

    fn backquote(&mut self) {
        if self
            .frames
            .last()
            .is_some_and(|frame| frame.opening == Opening::Backquote)
        {
            self.close_substitution();
        } else {
            self.open_substitution(Opening::Backquote);
        }
    }

    /// `$` outside single quotes: opens `$(` or reads past `$((…))`.
    fn dollar(&mut self, chars: &mut Chars<'_>) {
        if chars.peek() != Some(&'(') {
            self.push('$');
            return;
        }
        chars.next();
        if chars.peek() == Some(&'(') {
            chars.next();
            self.skip_arithmetic(chars);
        } else {
            self.open_substitution(Opening::Dollar);
        }
    }
}

/// The simple commands of a shell line, in the order they end.
fn simple_commands(line: &str) -> Vec<Segment> {
    let mut reader = Reader::default();
    let mut chars = line.chars().peekable();

    while let Some(character) = chars.next() {
        match (reader.quote, character) {
            (Some(open), _) if character == open => reader.quote = None,
            (Some('"'), '\\') => {
                if let Some(next) = chars.next() {
                    reader.push(next);
                }
            }
            // Substitutions open inside double quotes as well as outside.
            (None | Some('"'), '$') => reader.dollar(&mut chars),
            (None | Some('"'), '`') => reader.backquote(),
            (Some(_), _) => reader.push(character),
            (None, '\'' | '"') => {
                reader.quote = Some(character);
                reader.has_word = true;
            }
            (None, '\\') => match chars.next() {
                // A line continuation: the command goes on.
                Some('\n') | None => {}
                Some(next) => reader.push(next),
            },
            (None, '#') if !reader.has_word => {
                // A comment, up to the end of the line.
                while chars.peek().is_some_and(|next| *next != '\n') {
                    chars.next();
                }
            }
            (None, '>' | '<') => reader.redirect(character, &mut chars),
            (None, '&') if chars.peek() == Some(&'>') => {
                // `&>` sends both streams to a file.
                reader.finish_word();
                reader.redirect('>', &mut chars);
            }
            (None, '|' | '&') => reader.join(character, &mut chars),
            (None, ';') => {
                reader.finish_segment(false);
                // `;;` ends a `case` arm: another arm may be the one that ran.
                if chars.peek() == Some(&';') {
                    chars.next();
                    reader.is_branched = true;
                }
            }
            (None, '(') => reader.open_parenthesis(),
            (None, ')') => reader.close_parenthesis(),
            (None, '\n') => {
                reader.finish_segment(false);
                reader.skip_here_documents(&mut chars);
            }
            (None, character) if character.is_whitespace() => reader.finish_word(),
            (None, character) => reader.push(character),
        }
    }
    // An unclosed substitution's commands are still inside it.
    while !reader.frames.is_empty() {
        reader.close_substitution();
    }
    reader.finish_segment(false);
    reader.segments
}

/// The `NAME=value` words before a command's name, by name, and the rest.
fn split_assignments(words: &[String]) -> (Vec<&str>, &[String]) {
    let count = words
        .iter()
        .take_while(|word| assignment_name(word).is_some())
        .count();
    (
        words[..count]
            .iter()
            .filter_map(|word| assignment_name(word))
            .collect(),
        &words[count..],
    )
}

fn assignment_name(word: &str) -> Option<&str> {
    let (name, _) = word.split_once('=')?;
    (!name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
        .then_some(name)
}

/// A command with its wrappers read past.
struct Unwrapped<'a> {
    /// The variables the wrappers set (`env FILTER=x make test`).
    assignments: Vec<&'a str>,
    /// The command they run (`timeout 600 cargo test` is a `cargo test`).
    words: &'a [String],
    /// Whether `!` inverts its status.
    is_negated: bool,
}

fn unwrap(mut words: &[String]) -> Unwrapped<'_> {
    let mut assignments = Vec::new();
    let mut is_negated = false;
    loop {
        if words.first().is_some_and(|word| word == "!") {
            is_negated = !is_negated;
        }
        let rest = match words {
            // The words that open a compound command: what follows is a
            // command like any other.
            [first, rest @ ..]
                if matches!(
                    first.as_str(),
                    "{" | "!" | "if" | "then" | "do" | "else" | "elif" | "while" | "until"
                ) =>
            {
                rest
            }
            [first, rest @ ..]
                if matches!(first.as_str(), "time" | "nice" | "env" | "command" | "exec") =>
            {
                let (names, rest) = split_assignments(rest);
                assignments.extend(names);
                rest
            }
            [first, rest @ ..] if first == "timeout" => {
                // Its own flags, then the duration.
                let flags = rest.iter().take_while(|word| word.starts_with('-')).count();
                rest.get(flags + 1..).unwrap_or_default()
            }
            [first, second, rest @ ..]
                if matches!(first.as_str(), "uv" | "poetry" | "pipenv" | "pdm" | "hatch")
                    && second == "run" =>
            {
                // The runner's own flags (`uv run --frozen pytest`).
                let flags = rest.iter().take_while(|word| word.starts_with('-')).count();
                &rest[flags..]
            }
            [first, second, rest @ ..]
                if matches!(first.as_str(), "python" | "python3") && second == "-m" =>
            {
                rest
            }
            _ => {
                return Unwrapped {
                    assignments,
                    words,
                    is_negated,
                };
            }
        };
        words = rest;
    }
}

/// A tool's words as a pattern names them: `npm run test` is `npm test`,
/// `cargo +nightly test` is `cargo test`, and `make -j8 test` is `make
/// test` (make's own flags, with the value of those that take one).
fn tool_words(words: &[String]) -> Vec<&str> {
    let mut words: Vec<&str> = words.iter().map(String::as_str).collect();
    match words.first().copied() {
        Some("npm" | "pnpm" | "yarn" | "bun") if words.get(1) == Some(&"run") => {
            words.remove(1);
        }
        Some("cargo") if words.get(1).is_some_and(|word| word.starts_with('+')) => {
            words.remove(1);
        }
        Some("make") => {
            let index = 1;
            while let Some(word) = words.get(index) {
                if !word.starts_with('-') {
                    break;
                }
                let takes_value = matches!(*word, "-C" | "-f" | "-I" | "-j" | "-l" | "-o" | "-W")
                    && words.get(index + 1).is_some();
                let end = index + if takes_value { 2 } else { 1 };
                words.drain(index..end);
            }
        }
        _ => {}
    }
    words
}

/// Whether `words` start with `pattern`, whose last word may end in `*`.
fn matches(pattern: &[&str], words: &[&str]) -> bool {
    if words.len() < pattern.len() {
        return false;
    }
    pattern
        .iter()
        .zip(words)
        .all(|(expected, actual)| match expected.strip_suffix('*') {
            Some(prefix) => actual.starts_with(prefix),
            None => actual == expected,
        })
}

/// Whether a variable set on the command line narrows the run: one named for
/// what to run (`FILTER=`, `TESTS=`, `TEST_FILTER=`), judged by the last part
/// of its name so `RUST_TEST_THREADS` does not count.
fn narrows(name: &str) -> bool {
    let name = name.to_ascii_uppercase();
    let last = name.rsplit('_').next().unwrap_or(&name);
    matches!(
        last,
        "FILTER" | "FILTERS" | "TEST" | "TESTS" | "ONLY" | "GREP" | "PATTERN" | "SUITE"
    )
}

/// Flags that narrow the run. A flag on its own (`-v`, `--release`, `-j4`)
/// does not.
const NARROWING_FLAGS: &[&str] = &[
    "filter",
    "k",
    "run",
    "t",
    "grep",
    "test",
    "testNamePattern",
    "testPathPattern",
    "only",
    "p",
    "package",
    "skip",
    "m",
    "lf",
    "last-failed",
    "lib",
    "bin",
    "doc",
    "ignored",
];

/// Flags that take a value without narrowing the run, so the value is not
/// read as a name to run (`go test -count 1 ./...`).
const VALUE_FLAGS: &[&str] = &[
    "timeout",
    "count",
    "j",
    "jobs",
    "n",
    "numprocesses",
    "features",
    "F",
    "maxWorkers",
    "w",
    "workers",
    "reporter",
    "parallel",
    "target",
    "profile",
    "C",
];

/// Whether the words after the pattern narrow the run: a narrowing flag, a
/// variable assigned for `make`, a path, or a name. `./...` is Go's "every
/// package". An unknown flag that takes a value (`--seed 3`) reads as
/// narrowing, the safe side: "filtered" only withholds a claim about the
/// whole suite.
fn narrows_arguments(rest: &[&str]) -> bool {
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let word = *word;
        if word == "--" || word == "./..." {
            continue;
        }
        if let Some(name) = assignment_name(word) {
            if narrows(name) {
                return true;
            }
            continue;
        }
        if let Some(flag) = word.strip_prefix('-') {
            let flag = flag.trim_start_matches('-');
            let (name, has_value) = match flag.split_once('=') {
                Some((name, _)) => (name, true),
                None => (flag, false),
            };
            if NARROWING_FLAGS.contains(&name) {
                return true;
            }
            if VALUE_FLAGS.contains(&name) && !has_value {
                words.next();
            }
            continue;
        }
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(command: &str) -> Option<CheckRun> {
        classify(command, DEFAULT_CHECK_PATTERNS)
    }

    #[test]
    fn checks_classify_defaults_and_filters() {
        for whole in [
            "make test",
            "make test-swift",
            "cargo test --workspace",
            "npm test",
            "go test ./...",
            "pytest -q",
            "cd app && pnpm test",
            "swift test --parallel",
            "timeout 600 cargo test",
            "uv run pytest",
            "python -m pytest",
            "(cd app && npm test)",
            "cd app\nnpm test",
            "cargo test \\\n  --workspace",
            "RUST_TEST_THREADS=1 cargo test",
            "go test -timeout 10m ./...",
            "go test -count 1 ./...",
            "cargo test -j 4",
            "pytest -n auto",
            "make test # every suite",
        ] {
            let run = check(whole).unwrap_or_else(|| panic!("{whole:?} is a check"));
            assert!(!run.is_filtered, "{whole:?} runs the whole suite");
            assert!(run.is_exit_its_own, "{whole:?} ends with the check");
            assert_eq!(run.command, whole.trim());
        }
        for narrowed in [
            "make test-swift FILTER=TurnTimelineStoreTests",
            "FILTER=Turn make test",
            "env FILTER=Turn make test",
            "time TEST_FILTER=Turn make test",
            "swift test --filter TurnTests",
            "cargo test -p limpid-agent-core",
            "cargo test --lib",
            "cargo test turn_rules",
            "pytest tests/test_turns.py",
            "pytest -k turns",
            "pytest --lf",
            "go test -run TestTurn ./...",
            "npm test -- --testNamePattern=turn",
        ] {
            assert!(
                check(narrowed).is_some_and(|run| run.is_filtered),
                "{narrowed} is a filtered check"
            );
        }
        for other in [
            "make build",
            "cargo build",
            "npm install",
            "echo make test",
            "git status",
            "# make test",
            "",
        ] {
            assert_eq!(check(other), None, "{other:?} is not a check");
        }
    }

    #[test]
    fn a_redirection_is_not_an_argument() {
        for whole in [
            "cargo test 2>&1",
            "make test > /tmp/out.log",
            "npm test &> log.txt",
            "go test ./... >> out 2> err",
        ] {
            assert!(
                check(whole).is_some_and(|run| !run.is_filtered),
                "{whole} runs the whole suite"
            );
        }
    }

    #[test]
    fn the_exit_status_is_the_checks_only_when_nothing_follows_it() {
        for its_own in [
            "cargo test",
            "cd app && npm test",
            "make build; make test",
            "make test;",
            "make test\n",
            "make build && make test",
        ] {
            assert!(
                check(its_own).is_some_and(|run| run.is_exit_its_own),
                "{its_own:?}"
            );
        }
        for another in [
            "cargo test 2>&1 | tail -20",
            "make test || true",
            "false || make test",
            "make test && echo done",
            "make test; echo done",
            "make test\necho done",
            "make test &",
            "make test &\n",
            "make test & \n",
            "(make test) &\n",
            "(cargo test) | tail",
            "echo $(make test)",
            "x=$(make test)",
            "echo \"$(make test)\"",
            "echo `make test`",
        ] {
            assert!(
                check(another).is_none_or(|run| !run.is_exit_its_own),
                "{another:?} ends with something else"
            );
        }
        assert!(
            check("make test\necho done").is_some_and(|run| !run.is_filtered),
            "the next line is not an argument"
        );
    }

    #[test]
    fn a_quoted_substitution_goes_back_into_its_quotes() {
        for its_own in [
            r#"cd "$(git rev-parse --show-toplevel)" && make test"#,
            r#"export PATH="$(brew --prefix)/bin:$PATH" && cargo test"#,
            "git commit -m \"$(cat <<'EOF'\nfix: x\nEOF\n)\" && make test",
            "x=$( make test ) && make test",
            "{ make test; }",
        ] {
            assert!(
                check(its_own).is_some_and(|run| run.is_exit_its_own),
                "{its_own:?}"
            );
        }
        for not_a_check in [
            r#"echo "$(date); make test""#,
            r#"git commit -m "$(cat msg)" -m "ok | make test""#,
        ] {
            assert_eq!(check(not_a_check), None, "{not_a_check:?}");
        }
        for whole in [r#"make test > "$(mktemp)""#, "make test 2> $(mktemp)"] {
            assert!(
                check(whole).is_some_and(|run| !run.is_filtered),
                "{whole:?}: a substitution in a redirection is its target"
            );
        }
    }

    #[test]
    fn an_or_mark_survives_a_substitution() {
        for after_or in [
            r#"false || FILTER="$(cat f)" make test"#,
            r#"false || PATH="$(brew --prefix)/bin:$PATH" cargo test"#,
        ] {
            assert!(
                check(after_or).is_some_and(|run| !run.is_exit_its_own),
                "{after_or:?} runs only when the first failed"
            );
        }
    }

    #[test]
    fn a_runners_own_words_are_read_past() {
        for whole in [
            "npm run test",
            "pnpm run test",
            "make -j8 test",
            "make -C app test",
            "cargo +nightly test",
            "uv run --frozen pytest",
        ] {
            assert!(
                check(whole).is_some_and(|run| !run.is_filtered && run.is_exit_its_own),
                "{whole:?} is a whole check"
            );
        }
        for narrowed in ["cargo test --doc", "cargo test -- --ignored"] {
            assert!(
                check(narrowed).is_some_and(|run| run.is_filtered),
                "{narrowed:?} runs part of the suite"
            );
        }
    }

    #[test]
    fn a_substitution_closes_only_on_its_own_character() {
        assert!(
            check("echo $( (true); make test )").is_some_and(|run| !run.is_exit_its_own),
            "the subshell's ) does not close the $("
        );
        assert!(
            check("echo `make test`").is_some_and(|run| !run.is_exit_its_own),
            "backquotes"
        );
        assert!(
            check("echo $((1<<4))\nmake test").is_some_and(|run| run.is_exit_its_own),
            "arithmetic is not a here-document"
        );
    }

    #[test]
    fn compound_commands_are_read_through() {
        assert!(
            check("while true; do cargo test; done").is_some(),
            "a loop's command is a check"
        );
        assert!(
            check("! make test").is_some_and(|run| !run.is_exit_its_own),
            "! inverts the status"
        );
        for branched in [
            "if [ -f Makefile ]; then make test; else cargo test; fi",
            "case x in a) make test;; b) cargo test;; esac",
        ] {
            assert!(
                check(branched).is_some_and(|run| !run.is_exit_its_own),
                "{branched:?}: which branch ran is not known"
            );
        }
        assert!(
            check("if make test; then echo ok; fi").is_some_and(|run| !run.is_exit_its_own),
            "the if's status is its branch's"
        );
        assert!(
            check("{ make test; } | tail").is_some_and(|run| !run.is_exit_its_own),
            "piped on after the brace"
        );
    }

    #[test]
    fn a_check_that_may_not_have_run_has_no_status() {
        // Each exits 0 without running the test, so the status says nothing
        // about it.
        for unknown in [
            "if false; then make test; fi",
            "if false; then make test\nfi",
            "while false; do make test; done",
            "until true; do make test; done",
            "for f in; do make test; done",
            "case x in y) make test;; esac",
            "if true; then if false; then make test; fi; fi",
            "if false; then make test; fi > log",
        ] {
            assert!(
                check(unknown).is_some_and(|run| !run.is_exit_its_own),
                "{unknown:?}: the test may not have run"
            );
        }
        for its_own in [
            "if [ -d app ]; then cd app; fi; make test",
            "while false; do sleep 1; done\nmake test",
            "for f in a b; do echo $f; done && cargo test",
            "{ cd app; make test; }",
        ] {
            assert!(
                check(its_own).is_some_and(|run| run.is_exit_its_own),
                "{its_own:?}: the check runs after the compound command"
            );
        }
    }

    #[test]
    fn a_here_document_is_not_run() {
        let line = "make build && cat > ci.sh <<'EOF'\ncargo test\nEOF\nmake lint";
        assert_eq!(check(line), None, "the body is text, not a command");
        let indented = "cat <<EOF\n  EOF\nmake test\nEOF\nmake build";
        assert_eq!(
            check(indented),
            None,
            "an indented delimiter does not end a <<"
        );
        let tabbed = "cat <<-EOF\n\tmake test\n\tEOF\nmake test";
        assert!(
            check(tabbed).is_some_and(|run| run.is_exit_its_own),
            "<<- strips tabs"
        );
        let then = "cat <<EOF > notes\nmake test\nEOF\nmake test";
        assert!(
            check(then).is_some_and(|run| run.is_exit_its_own),
            "the command after the body is read"
        );
    }

    #[test]
    fn a_project_replaces_the_defaults() {
        let mine = ["just check", "bun test*"];
        assert!(classify("just check", &mine).is_some());
        assert!(classify("bun test:unit", &mine).is_some());
        assert_eq!(
            classify("cargo test", &mine),
            None,
            "the defaults no longer apply"
        );
        let none: [&str; 0] = [];
        assert_eq!(
            classify("cargo test", &none),
            None,
            "an empty list turns checks off"
        );
    }

    #[test]
    fn quotes_and_escapes_stay_in_one_word() {
        assert!(check(r#"swift test --filter "Turn Tests""#).is_some_and(|run| run.is_filtered));
        assert_eq!(check(r#"echo "make test""#), None);
        assert_eq!(check(r#"echo "a | make test""#), None);
        assert_eq!(check("echo 'make test # not a comment'"), None);
    }
}
