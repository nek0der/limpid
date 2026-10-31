//! Detection of `git worktree add` in a shell command the agent is about to
//! run. Both providers hand the Bash tool the same command string, so the
//! parse is provider-neutral; what a provider adds is only where the command
//! sits in its payload.

use crate::{MAX_HOOK_INPUT_BYTES, NormalizeError, parse_object};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A `git worktree add -b <branch> …` the agent asked its shell tool to run.
/// The hook runtime may intercept it and create the worktree where the
/// project's placement rules say, then report back through the tool result.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorktreeIntent {
    /// The full command line as the agent wrote it.
    pub command: String,
    /// The branch named by `-b`, `-B`, or `--branch=`.
    pub branch: String,
    /// The agent's working directory when it issued the command.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
}

impl WorktreeIntent {
    /// Reads the intent out of a `PreToolUse` hook payload in the shape
    /// Claude Code defined and Codex adopted: `tool_name` names the shell
    /// tool and `tool_input.command` carries the command line. Providers
    /// with that payload shape delegate here; others parse their own.
    ///
    /// # Errors
    ///
    /// Returns `NormalizeError` only for input that is too large or is not a
    /// JSON object.
    pub fn from_hook_payload(
        bytes: &[u8],
        shell_tool: &str,
    ) -> Result<Option<Self>, NormalizeError> {
        let object = parse_object(bytes, MAX_HOOK_INPUT_BYTES)?;
        let string = |key: &str| object.get(key).and_then(Value::as_str);
        if string("hook_event_name") != Some("PreToolUse")
            || string("tool_name") != Some(shell_tool)
        {
            return Ok(None);
        }
        let Some(command) = object
            .get("tool_input")
            .and_then(|tool_input| tool_input.get("command"))
            .and_then(Value::as_str)
        else {
            return Ok(None);
        };
        Ok(Self::parse(command, string("cwd")))
    }

    /// Parses `command` the way the shell intercept did: the command must
    /// start with `git`, reach `worktree add` before any `|`, `;`, or `&`,
    /// and name a branch. Anything else is not an intent, because renaming a
    /// worktree on the agent's behalf would be noisier than letting the
    /// original command run.
    #[must_use]
    pub fn parse(command: &str, cwd: Option<&str>) -> Option<Self> {
        let tokens: Vec<&str> = command.split_whitespace().collect();
        if tokens.first() != Some(&"git") {
            return None;
        }
        let mut after_add = false;
        let mut previous = "";
        let mut branch: Option<&str> = None;
        for token in &tokens[1..] {
            if !after_add {
                if token.contains(['|', ';', '&']) {
                    return None;
                }
                if previous == "worktree" && *token == "add" {
                    after_add = true;
                }
                previous = token;
                continue;
            }
            match *token {
                "-b" | "-B" => previous = token,
                _ if token.starts_with("--branch=") => {
                    branch = Some(&token["--branch=".len()..]);
                    previous = "";
                }
                _ if token.starts_with('-') => previous = "",
                _ => {
                    if previous == "-b" || previous == "-B" {
                        branch = Some(token);
                    }
                    previous = "";
                }
            }
        }
        let branch = branch.filter(|value| !value.is_empty())?;
        after_add.then(|| Self {
            command: command.to_owned(),
            branch: branch.to_owned(),
            cwd: cwd.map(str::to_owned),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_branch_flags_in_every_spelling() {
        for command in [
            "git worktree add -b demo ../demo",
            "  git -C repo worktree add ../demo -B demo",
            "git worktree add --branch=demo ../demo && git worktree list",
        ] {
            let intent = WorktreeIntent::parse(command, Some("/repo")).expect(command);
            assert_eq!(intent.branch, "demo");
            assert_eq!(intent.cwd.as_deref(), Some("/repo"));
        }
    }

    #[test]
    fn ignores_commands_that_are_not_a_worktree_add() {
        for command in [
            "git worktree list",
            "git worktree add ../demo",
            "ls | git worktree add -b demo ../demo",
            "echo git worktree add -b demo x",
            "git status; git worktree add -b demo ../demo",
        ] {
            assert_eq!(WorktreeIntent::parse(command, None), None, "{command}");
        }
    }
}
