//! This is the git runner the hook's fixtures share, for the integration tests'
//! `support` module and the restore unit tests alike (which include this
//! file by path, as a unit test cannot reach `tests/`).

use std::path::Path;
use std::process::{Command, Output};

/// Runs git in `cwd` without the developer's own configuration, so a global
/// `commit.gpgsign` or `core.hooksPath` cannot stall the fixture setup. The
/// result is the bare output: whether a failed exit is an answer or a broken
/// fixture is the wrappers' call.
pub fn run(cwd: &Path, args: &[&str]) -> std::io::Result<Output> {
    Command::new("git")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .output()
}

/// Does what `run` does, for a step the fixture needs: a git that cannot
/// start, or exits with a failure, fails the test there, and otherwise the
/// trimmed output is returned.
pub fn required(cwd: &Path, args: &[&str]) -> String {
    let output = run(cwd, args).expect("git runs");
    assert!(output.status.success(), "git {args:?}");
    stdout(&output)
}

/// Does what `run` does, for a step whose failed exit is an answer (a ref
/// that is not there), and returns `None` for that exit. A git that cannot
/// start still fails the test, so a broken fixture is never read as that
/// answer.
pub fn optional(cwd: &Path, args: &[&str]) -> Option<String> {
    let output = run(cwd, args).expect("git runs");
    output.status.success().then(|| stdout(&output))
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}
