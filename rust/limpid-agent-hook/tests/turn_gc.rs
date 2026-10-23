//! Deleting turns (`turn_gc`): the record and its refs go together, and a
//! deletion cut short is finished by the next call. Unix only: the hook runtime
//! itself only runs there.
#![cfg(unix)]

mod support;

use limpid_agent_hook::{
    GitSnapshots, SnapshotRunner, TURNS_DIRECTORY, TurnDeletion, TurnSide, delete_turns,
};
use limpid_agent_model::TurnRecord;
use std::fs;
use std::path::{Path, PathBuf};
use support::{Repo, git, recorded_turn, turn_ref};

#[test]
fn delete_turn_removes_manifest_and_refs_together() {
    let repo = Repo::new("gc");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    assert!(turn_ref(&repo, &turn.turn_id, "begin").is_some());

    let outcome = delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots);

    assert_eq!(
        outcome,
        vec![TurnDeletion::Deleted {
            turn_id: turn.turn_id.clone()
        }]
    );
    assert!(!turns.join(format!("{}.turn.json", turn.turn_id)).exists());
    assert_eq!(turn_ref(&repo, &turn.turn_id, "begin"), None);
    assert_eq!(turn_ref(&repo, &turn.turn_id, "end"), None);
    assert!(
        !fs::read_dir(&turns)
            .expect("turns")
            .flatten()
            .any(|entry| entry.file_name().to_string_lossy().ends_with(".deleting")),
        "nothing left aside"
    );
}

#[test]
fn delete_turn_is_idempotent() {
    let repo = Repo::new("gc-again");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    let ids = [turn.turn_id.clone()];
    let _ = delete_turns(&turns, &ids, &GitSnapshots);

    assert_eq!(
        delete_turns(&turns, &ids, &GitSnapshots),
        vec![TurnDeletion::AlreadyGone {
            turn_id: turn.turn_id.clone()
        }]
    );
    assert!(matches!(
        delete_turns(&turns, &["not-a-turn".to_owned()], &GitSnapshots)[..],
        [TurnDeletion::Failed { .. }]
    ));
}

#[test]
fn a_deletion_cut_short_is_finished_by_the_next_call() {
    let repo = Repo::new("gc-resume");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    // As if a call moved the record aside and stopped there.
    let record = turns.join(format!("{}.turn.json", turn.turn_id));
    let aside = turns.join(format!(".{}.turn.json.deleting", turn.turn_id));
    fs::rename(&record, &aside).expect("aside");

    let deletions = delete_turns(&turns, &[], &GitSnapshots);

    assert!(!aside.exists());
    assert_eq!(turn_ref(&repo, &turn.turn_id, "end"), None);
    // Reported though nobody asked for it, so the host forgets it.
    assert_eq!(
        deletions,
        vec![TurnDeletion::Deleted {
            turn_id: turn.turn_id.clone()
        }]
    );
}

/// Git refusing every ref deletion.
struct RefusingRefs;

impl SnapshotRunner for RefusingRefs {
    fn capture(
        &self,
        cwd: &Path,
        pane_id: &str,
        side: TurnSide,
    ) -> limpid_agent_core::SnapshotTaken {
        GitSnapshots.capture(cwd, pane_id, side)
    }

    fn worktree(&self, cwd: &Path) -> Option<(PathBuf, PathBuf)> {
        GitSnapshots.worktree(cwd)
    }

    fn diff(&self, root: &Path, begin: &str, end: &str) -> Option<limpid_agent_model::DiffStat> {
        GitSnapshots.diff(root, begin, end)
    }

    fn pin(&self, root: &Path, turn_id: &str, side: TurnSide, tree: &str) -> Result<(), String> {
        GitSnapshots.pin(root, turn_id, side, tree)
    }

    fn unpin(
        &self,
        _root: &Path,
        _common_dir: Option<&Path>,
        _turn_id: &str,
    ) -> Result<bool, String> {
        Err("refused".to_owned())
    }

    fn remove(&self, cwd: &Path, pane_id: &str) -> Result<(), String> {
        GitSnapshots.remove(cwd, pane_id)
    }
}

#[test]
fn a_ref_git_refuses_puts_the_record_back_and_an_unreadable_record_stays() {
    let repo = Repo::new("gc-refused");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    let record = turns.join(format!("{}.turn.json", turn.turn_id));

    let outcome = delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &RefusingRefs);

    assert!(matches!(outcome[..], [TurnDeletion::Failed { .. }]));
    assert!(record.exists(), "the next sweep asks again");
    assert!(turn_ref(&repo, &turn.turn_id, "begin").is_some());

    // A newer build's record: its refs may be named where this one cannot
    // read.
    fs::write(&record, br#"{"schemaVersion":99}"#).expect("newer");
    assert_eq!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots),
        vec![TurnDeletion::Unreadable {
            turn_id: turn.turn_id.clone()
        }]
    );
    assert!(record.exists());
    assert!(turn_ref(&repo, &turn.turn_id, "begin").is_some());
}

fn record_path(turns: &Path, turn_id: &str) -> PathBuf {
    turns.join(format!("{turn_id}.turn.json"))
}

fn aside_path(turns: &Path, turn_id: &str) -> PathBuf {
    turns.join(format!(".{turn_id}.turn.json.deleting"))
}

/// The record with its JSON changed by `edit`.
fn rewrite(path: &Path, edit: impl FnOnce(&mut serde_json::Value)) {
    let mut value: serde_json::Value =
        serde_json::from_slice(&fs::read(path).expect("read")).expect("json");
    edit(&mut value);
    fs::write(path, serde_json::to_vec(&value).expect("encode")).expect("write");
}

#[test]
fn a_record_this_build_may_not_rewrite_is_neither_moved_nor_deleted() {
    let repo = Repo::new("gc-newer");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    let record = record_path(&turns, &turn.turn_id);
    let original = fs::read(&record).expect("read");

    for edit in [
        // A newer writer's record that still reads in this shape.
        (|value: &mut serde_json::Value| value["schemaVersion"] = 2.into())
            as fn(&mut serde_json::Value),
        // A snapshot status this build reads only as unknown.
        |value: &mut serde_json::Value| value["begin"] = serde_json::json!({"kind": "lfs"}),
    ] {
        fs::write(&record, &original).expect("restore");
        rewrite(&record, edit);
        assert_eq!(
            delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots),
            vec![TurnDeletion::Unreadable {
                turn_id: turn.turn_id.clone()
            }]
        );
        assert!(record.exists());
        assert!(
            !aside_path(&turns, &turn.turn_id).exists(),
            "not even moved"
        );
        assert!(turn_ref(&repo, &turn.turn_id, "end").is_some());
    }
}

#[test]
fn a_removed_worktree_still_reaches_its_refs_through_the_common_directory() {
    let repo = Repo::new("gc-gone-root");
    let gone = repo.root.join("removed");
    let (turns, turn) = turn_naming(&repo, &gone, true);

    assert_eq!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots),
        vec![TurnDeletion::Deleted {
            turn_id: turn.turn_id.clone()
        }]
    );
    assert_eq!(turn_ref(&repo, &turn.turn_id, "begin"), None);
    assert_eq!(turn_ref(&repo, &turn.turn_id, "end"), None);
}

#[test]
fn a_removed_worktree_with_no_common_directory_recorded_leaves_its_refs() {
    let repo = Repo::new("gc-gone-root-old");
    let gone = repo.root.join("removed");
    let (turns, turn) = turn_naming(&repo, &gone, false);

    assert_eq!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots),
        vec![TurnDeletion::DeletedLeavingRefs {
            turn_id: turn.turn_id.clone(),
            roots: vec![gone.to_str().expect("path").to_owned()]
        }]
    );
    assert!(!record_path(&turns, &turn.turn_id).exists());
}

#[test]
fn a_turn_records_its_common_directory_and_what_it_added() {
    let repo = Repo::new("gc-recorded");
    let (_, turn) = recorded_turn(&repo);
    let common = turn
        .git_context
        .as_ref()
        .and_then(|context| context.common_dir.as_deref())
        .expect("common dir");
    assert_eq!(
        Path::new(common).canonicalize().ok(),
        repo.git_dir().canonicalize().ok()
    );
    // README.md grew to 16 bytes ("fixture\nchanged\n").
    assert_eq!(turn.added_bytes, Some(16));
}

#[test]
fn a_turn_missing_one_ref_is_still_deleted_whole() {
    let repo = Repo::new("gc-one-ref");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    git(
        &repo.path,
        &[
            "update-ref",
            "-d",
            &format!("refs/limpid/turns/{}/end", turn.turn_id),
        ],
    );

    assert_eq!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots),
        vec![TurnDeletion::Deleted {
            turn_id: turn.turn_id.clone()
        }]
    );
    assert_eq!(turn_ref(&repo, &turn.turn_id, "begin"), None);
}

#[test]
fn a_cut_short_deletion_of_a_turn_written_again_leaves_the_newer_record() {
    let repo = Repo::new("gc-written-again");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    let record = record_path(&turns, &turn.turn_id);
    let aside = aside_path(&turns, &turn.turn_id);
    fs::copy(&record, &aside).expect("aside");
    // The turn is written again after the copy went aside, so the record
    // differs from that copy, and keeping the copy in its place would show.
    rewrite(&record, |value| {
        value["finishedAt"] = "2026-10-13T00:00:01Z".into();
    });
    let newer = fs::read(&record).expect("newer");
    let pinned = (
        turn_ref(&repo, &turn.turn_id, "begin"),
        turn_ref(&repo, &turn.turn_id, "end"),
    );

    let outcome = delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots);

    assert!(matches!(outcome[..], [TurnDeletion::Failed { .. }]));
    assert_eq!(
        fs::read(&record).ok(),
        Some(newer),
        "the newer record stays"
    );
    assert!(!aside.exists());
    assert!(pinned.0.is_some() && pinned.1.is_some());
    assert_eq!(
        (
            turn_ref(&repo, &turn.turn_id, "begin"),
            turn_ref(&repo, &turn.turn_id, "end"),
        ),
        pinned
    );
}

#[test]
fn an_unreadable_record_left_aside_is_put_back() {
    let repo = Repo::new("gc-put-back");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    let record = record_path(&turns, &turn.turn_id);
    let aside = aside_path(&turns, &turn.turn_id);
    rewrite(&record, |value| value["schemaVersion"] = 2.into());
    fs::rename(&record, &aside).expect("aside");

    let _ = delete_turns(&turns, &[], &GitSnapshots);

    assert!(record.exists(), "readers find it again");
    assert!(!aside.exists());
}

#[test]
fn a_turn_asked_for_and_left_aside_is_reported_as_deleted() {
    let repo = Repo::new("gc-asked-aside");
    let (states, turn) = recorded_turn(&repo);
    let turns = states.join(TURNS_DIRECTORY);
    fs::rename(
        record_path(&turns, &turn.turn_id),
        aside_path(&turns, &turn.turn_id),
    )
    .expect("aside");

    assert_eq!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots),
        vec![TurnDeletion::Deleted {
            turn_id: turn.turn_id.clone()
        }]
    );
}

/// A recorded turn whose snapshots name `root` instead of the repository;
/// without `keeps_common_dir`, as a record from before the common directory
/// was kept.
fn turn_naming(repo: &Repo, root: &Path, keeps_common_dir: bool) -> (PathBuf, TurnRecord) {
    let (states, turn) = recorded_turn(repo);
    let turns = states.join(TURNS_DIRECTORY);
    rewrite(&record_path(&turns, &turn.turn_id), |value| {
        for side in ["begin", "end"] {
            value[side]["root"] = root.to_str().expect("path").into();
        }
        if !keeps_common_dir && let Some(context) = value["gitContext"].as_object_mut() {
            context.remove("commonDir");
        }
    });
    (turns, turn)
}

#[test]
fn a_directory_that_is_no_repository_now_leaves_nothing_to_reach() {
    let repo = Repo::new("gc-not-repo");
    let empty = repo.root.join("emptied");
    fs::create_dir_all(&empty).expect("dir");
    let (turns, turn) = turn_naming(&repo, &empty, false);

    assert!(matches!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots)[..],
        [TurnDeletion::DeletedLeavingRefs { .. }]
    ));

    // With the common directory recorded, the refs are reached through it.
    let repo = Repo::new("gc-not-repo-common");
    let empty = repo.root.join("emptied");
    fs::create_dir_all(&empty).expect("dir");
    let (turns, turn) = turn_naming(&repo, &empty, true);
    assert!(matches!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots)[..],
        [TurnDeletion::Deleted { .. }]
    ));
    assert_eq!(turn_ref(&repo, &turn.turn_id, "end"), None);
}

#[test]
fn a_worktree_whose_git_directory_is_gone_leaves_nothing_to_reach() {
    let repo = Repo::new("gc-moved-gitdir");
    let linked = repo.root.join("linked");
    fs::create_dir_all(&linked).expect("dir");
    fs::write(
        linked.join(".git"),
        "gitdir: ../gone/.git/worktrees/linked\n",
    )
    .expect(".git");
    let (turns, turn) = turn_naming(&repo, &linked, false);

    assert!(matches!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots)[..],
        [TurnDeletion::DeletedLeavingRefs { .. }]
    ));
}

#[test]
fn git_failing_in_a_repository_still_there_keeps_the_record() {
    let repo = Repo::new("gc-git-fails");
    // A `.git` git cannot read: the repository is there, so its refs may be.
    // Inside the fixture repository, so git searching upward would find
    // one and report the refs deleted there.
    let broken = repo.path.join("broken");
    fs::create_dir_all(broken.join(".git")).expect("dir");
    let (turns, turn) = turn_naming(&repo, &broken, false);

    assert!(matches!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots)[..],
        [TurnDeletion::Failed { .. }]
    ));
    assert!(record_path(&turns, &turn.turn_id).exists());
}

#[test]
fn a_linked_worktree_reaches_the_refs_it_shares_with_its_repository() {
    let repo = Repo::new("gc-linked");
    let linked = repo.root.join("linked");
    git(
        &repo.path,
        &[
            "worktree",
            "add",
            "-q",
            "--detach",
            linked.to_str().expect("path"),
        ],
    )
    .expect("worktree");
    let (turns, turn) = turn_naming(&repo, &linked, true);

    assert_eq!(
        delete_turns(&turns, std::slice::from_ref(&turn.turn_id), &GitSnapshots),
        vec![TurnDeletion::Deleted {
            turn_id: turn.turn_id.clone()
        }]
    );
    assert_eq!(turn_ref(&repo, &turn.turn_id, "begin"), None);
    assert_eq!(turn_ref(&repo, &turn.turn_id, "end"), None);
}
