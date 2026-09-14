//! Routing the side records a hook writes: a pane's working directory
//! changing, and a worktree an agent created.
//!
//! Both are one-shot events delivered through the filesystem, so both need to
//! be told apart from the state that was already there when the pass started.
//! A working directory record is overwritten in place, so its timestamp is
//! what marks it fresh; a worktree event gets its own file, so its name is.
//! Either way the first pass after launch only takes note. Announcing a move
//! the user made yesterday, or re-running a sync for a worktree that already
//! exists, would be worse than saying nothing.

use limpid_agent_model::{
    Command, CommandOp, Precondition, ProjectionInput, ProjectionState, Target,
};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsStr;
use std::path::Path;
use uuid::Uuid;

/// Updates what has been seen and returns what to route.
pub(crate) fn route(
    state: &mut ProjectionState,
    input: &ProjectionInput,
    alive: &BTreeSet<Uuid>,
) -> Vec<Command> {
    let mut commands = route_cwd(state, input, alive);
    commands.extend(route_worktrees(state, input));
    commands
}

/// A pane that has moved somewhere else deserves an offer to move its
/// worktree with it, but only once and only while the pane is still open.
fn route_cwd(
    state: &mut ProjectionState,
    input: &ProjectionInput,
    alive: &BTreeSet<Uuid>,
) -> Vec<Command> {
    let mut commands = Vec::new();
    let mut seen: BTreeMap<Uuid, String> = BTreeMap::new();
    for file in &input.cwd_events {
        let Some(content) = file.content.as_deref() else {
            // Unreadable this pass. Carry the timestamp forward so the record
            // is not mistaken for a new move once it can be read again.
            if let Ok(pane) = Uuid::parse_str(&file.name)
                && let Some(previous) = state.cwd_seen.get(&pane)
            {
                seen.insert(pane, previous.clone());
            }
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(content) else {
            continue;
        };
        let Some(pane) = value
            .get("paneId")
            .and_then(Value::as_str)
            .and_then(|it| Uuid::parse_str(it).ok())
        else {
            continue;
        };
        let updated_at = value
            .get("updatedAt")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let is_fresh = state.cwd_seen.get(&pane) != Some(&updated_at);
        seen.insert(pane, updated_at);
        if !is_fresh || input.is_bootstrap {
            continue;
        }
        let Some(new_cwd) = value
            .get("newCwd")
            .and_then(Value::as_str)
            .filter(|it| !it.is_empty())
        else {
            continue;
        };
        // The pane is gone, so there is nothing left to offer to move.
        if !alive.contains(&pane) {
            continue;
        }
        commands.push(Command::new(
            CommandOp::CwdChanged {
                pane,
                new_cwd: new_cwd.to_owned(),
                old_cwd: value
                    .get("oldCwd")
                    .and_then(Value::as_str)
                    .filter(|it| !it.is_empty())
                    .map(str::to_owned),
            },
            Target::Host,
            Precondition::None,
        ));
    }
    // Panes that closed take their history with them, so a pane id handed out
    // again starts clean.
    seen.retain(|pane, _| alive.contains(pane));
    state.cwd_seen = seen;
    commands
}

/// A worktree an agent created is news for exactly one pass: refetch the
/// repository it landed in, then consume the file.
fn route_worktrees(state: &mut ProjectionState, input: &ProjectionInput) -> Vec<Command> {
    let mut names: Vec<&limpid_agent_model::WorktreeEventFile> = input
        .worktree_events
        .iter()
        // A file still being written is not an event yet. Reading one would
        // parse half a record and then delete it before the writer could
        // rename, losing the event outright. The hook names its temporary
        // with a leading dot and a pid suffix; the shell receiver it replaced
        // used a `.tmp` extension, and both writers can still be on disk.
        .filter(|file| {
            !file.file_name.starts_with('.')
                && Path::new(&file.file_name).extension() != Some(OsStr::new("tmp"))
        })
        .collect();
    // Names carry a timestamp, so sorting them processes a burst in the order
    // the events happened rather than the order the directory listed them.
    names.sort_by(|left, right| left.file_name.cmp(&right.file_name));

    let mut commands = Vec::new();
    let fresh: Vec<&limpid_agent_model::WorktreeEventFile> = names
        .iter()
        .copied()
        .filter(|file| !state.worktree_seen.contains(&file.file_name))
        .collect();

    // The first pass after launch only takes note. It deliberately does not
    // consume anything, because a hook may be mid-write on a file whose final
    // name is already visible.
    if !input.is_bootstrap {
        for file in fresh {
            if let Some(repo_root) = repo_root(file.content.as_str()) {
                commands.push(Command::new(
                    CommandOp::GitSyncRefetch { repo_root },
                    Target::Host,
                    Precondition::None,
                ));
            }
            // Consumed whether or not it parsed. An unreadable event will
            // never become readable, and leaving it would re-examine it on
            // every pass for the life of the session.
            commands.push(Command::new(
                CommandOp::Delete,
                Target::WorktreeEvent {
                    provider: file.provider.clone(),
                    file_name: file.file_name.clone(),
                },
                Precondition::Exists,
            ));
        }
    }

    // Bounded by what is actually in the directory: a file that has been
    // consumed drops out on the next pass, and one whose delete failed stays
    // and is not routed twice.
    state.worktree_seen = names
        .into_iter()
        .map(|file| file.file_name.clone())
        .collect();
    commands
}

/// The repository the worktree landed in. The host matches it against its
/// projects rather than the rules doing it, because the comparison resolves
/// symbolic links against the filesystem and the project list is the host's.
fn repo_root(content: &str) -> Option<String> {
    serde_json::from_str::<Value>(content)
        .ok()?
        .get("repoRoot")?
        .as_str()
        .filter(|it| !it.is_empty())
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;
    use limpid_agent_model::{ProviderId, RecordFile, WorktreeEventFile};

    const PANE: &str = "11111111-1111-4111-8111-111111111111";

    fn pane() -> Uuid {
        PANE.parse().expect("pane")
    }

    fn claude() -> ProviderId {
        ProviderId::new("claude").expect("provider id")
    }

    fn cwd_file(updated_at: &str) -> RecordFile {
        RecordFile {
            provider: claude(),
            name: PANE.to_owned(),
            content: Some(format!(
                r#"{{"schemaVersion":1,"paneId":"{PANE}","newCwd":"/tmp/after",
                   "oldCwd":"/tmp/before","updatedAt":"{updated_at}"}}"#
            )),
        }
    }

    fn worktree_file(name: &str, repo_root: &str) -> WorktreeEventFile {
        WorktreeEventFile {
            provider: claude(),
            file_name: name.to_owned(),
            content: format!(
                r#"{{"schemaVersion":1,"event":"create","repoRoot":"{repo_root}",
                   "worktreePath":"/tmp/wt","branch":"demo"}}"#
            ),
        }
    }

    fn alive() -> BTreeSet<Uuid> {
        [pane()].into_iter().collect()
    }

    fn cwd_changes(commands: &[Command]) -> Vec<&CommandOp> {
        commands
            .iter()
            .map(|command| &command.op)
            .filter(|op| matches!(op, CommandOp::CwdChanged { .. }))
            .collect()
    }

    #[test]
    fn a_move_routes_once_and_only_while_the_pane_is_open() {
        let mut state = ProjectionState::default();
        let input = ProjectionInput {
            cwd_events: vec![cwd_file("2026-09-14T12:00:00Z")],
            ..ProjectionInput::default()
        };
        assert_eq!(cwd_changes(&route(&mut state, &input, &alive())).len(), 1);

        // The same record on a rescan is the same move.
        assert!(cwd_changes(&route(&mut state, &input, &alive())).is_empty());

        // A later move on the same pane is a new one.
        let later = ProjectionInput {
            cwd_events: vec![cwd_file("2026-09-14T12:05:00Z")],
            ..ProjectionInput::default()
        };
        assert_eq!(cwd_changes(&route(&mut state, &later, &alive())).len(), 1);

        // Once the pane is gone the offer is moot, and its history goes too.
        let mut state = ProjectionState::default();
        let closed = BTreeSet::new();
        assert!(cwd_changes(&route(&mut state, &input, &closed)).is_empty());
        assert!(state.cwd_seen.is_empty());
    }

    #[test]
    fn the_first_pass_after_launch_only_takes_note_of_a_move() {
        // The move happened before Limpid opened. Offering to act on it now
        // would be acting on something the user has long since moved past.
        let mut state = ProjectionState::default();
        let input = ProjectionInput {
            cwd_events: vec![cwd_file("2026-09-14T12:00:00Z")],
            is_bootstrap: true,
            ..ProjectionInput::default()
        };
        assert!(cwd_changes(&route(&mut state, &input, &alive())).is_empty());
        assert_eq!(state.cwd_seen.len(), 1);
    }

    #[test]
    fn an_unreadable_move_is_not_mistaken_for_a_new_one_later() {
        let mut state = ProjectionState::default();
        let input = ProjectionInput {
            cwd_events: vec![cwd_file("2026-09-14T12:00:00Z")],
            ..ProjectionInput::default()
        };
        route(&mut state, &input, &alive());

        let unreadable = ProjectionInput {
            cwd_events: vec![RecordFile {
                content: None,
                ..cwd_file("ignored")
            }],
            ..ProjectionInput::default()
        };
        assert!(cwd_changes(&route(&mut state, &unreadable, &alive())).is_empty());

        // Readable again, same record: still the same move.
        assert!(cwd_changes(&route(&mut state, &input, &alive())).is_empty());
    }

    #[test]
    fn a_worktree_event_syncs_its_repository_and_is_consumed() {
        let mut state = ProjectionState::default();
        let input = ProjectionInput {
            worktree_events: vec![worktree_file("0001-create.json", "/repo")],
            ..ProjectionInput::default()
        };
        let commands = route(&mut state, &input, &BTreeSet::new());
        assert!(matches!(
            &commands[0].op,
            CommandOp::GitSyncRefetch { repo_root } if repo_root == "/repo"
        ));
        assert!(matches!(commands[1].op, CommandOp::Delete));

        // Still present because the delete has not landed yet; it must not be
        // routed a second time.
        let repeat = route(&mut state, &input, &BTreeSet::new());
        assert!(repeat.is_empty());
    }

    #[test]
    fn a_file_still_being_written_is_left_alone() {
        // Reading a half-written file would parse nothing and then delete it
        // before the hook could rename, losing the event outright.
        let mut state = ProjectionState::default();
        let input = ProjectionInput {
            worktree_events: vec![
                // The shell receiver's temporary name.
                worktree_file("0001-create.json.tmp", "/repo"),
                // The hook's: a leading dot, and the writer's pid where an
                // extension would be, so matching on the extension misses it.
                worktree_file(".0002-create.json.tmp.4242", "/repo"),
            ],
            ..ProjectionInput::default()
        };
        assert!(route(&mut state, &input, &BTreeSet::new()).is_empty());
        assert!(state.worktree_seen.is_empty());
    }

    #[test]
    fn an_unparseable_event_is_consumed_without_a_sync() {
        let mut state = ProjectionState::default();
        let input = ProjectionInput {
            worktree_events: vec![WorktreeEventFile {
                content: "not json".to_owned(),
                ..worktree_file("0001-create.json", "/repo")
            }],
            ..ProjectionInput::default()
        };
        let commands = route(&mut state, &input, &BTreeSet::new());
        assert_eq!(commands.len(), 1);
        assert!(matches!(commands[0].op, CommandOp::Delete));
    }

    #[test]
    fn a_burst_is_routed_in_the_order_the_events_happened() {
        let mut state = ProjectionState::default();
        let input = ProjectionInput {
            worktree_events: vec![
                worktree_file("0002-create.json", "/second"),
                worktree_file("0001-create.json", "/first"),
            ],
            ..ProjectionInput::default()
        };
        let commands = route(&mut state, &input, &BTreeSet::new());
        let roots: Vec<&str> = commands
            .iter()
            .filter_map(|command| match &command.op {
                CommandOp::GitSyncRefetch { repo_root } => Some(repo_root.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(roots, vec!["/first", "/second"]);
    }
}
