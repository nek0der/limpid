//! Undoing a restore: what goes back, and what an undo refuses to write over.

use super::*;

#[test]
fn undo_puts_the_tree_back_and_marks_the_restore() {
    let repo = Repo::new("undo");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));

    let undo = finished(repo.undo(&restored.op_id));

    assert_eq!(undo.stage, RestoreStage::Applied);
    assert_eq!(undo.undoes.as_deref(), Some(restored.op_id.as_str()));
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\nchanged\n"));
    assert_eq!(repo.read("new/made.txt").as_deref(), Some("made\n"));
    assert_eq!(repo.read("keep.txt"), None);
    assert_eq!(
        repo.worktree()
            .journal(&restored.op_id)
            .unwrap()
            .unwrap()
            .stage,
        RestoreStage::Undone { by: undo.op_id }
    );
    assert_eq!(refused(repo.undo(&restored.op_id)), Refusal::NotUndoable);
}

#[test]
fn undo_refuses_after_further_edits() {
    let repo = Repo::new("undo-edited");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    repo.write("a.txt", "later\n");

    assert_eq!(
        refused(repo.undo(&restored.op_id)),
        Refusal::ChangedSinceRestore {
            paths: vec!["a.txt".to_owned()]
        }
    );
    assert_eq!(repo.read("a.txt").as_deref(), Some("later\n"));
}

#[test]
fn undo_of_a_restore_keeps_what_others_changed_elsewhere() {
    let repo = Repo::new("undo-outside");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    repo.write("other.txt", "outside\n");

    let undo = finished(repo.undo(&restored.op_id));

    assert_eq!(undo.stage, RestoreStage::Applied);
    assert_eq!(repo.read("other.txt").as_deref(), Some("outside\n"));
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\nchanged\n"));
}

/// A path someone put back by hand is left alone; the rest is undone.
#[test]
fn undo_writes_back_only_the_paths_that_hold_the_restore() {
    let repo = Repo::new("undo-some");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    repo.write("a.txt", "a\nchanged\n");

    let undo = finished(repo.undo(&restored.op_id));

    assert_eq!(undo.stage, RestoreStage::Applied);
    assert!(
        !undo
            .planned_paths
            .iter()
            .any(|change| change.path == "a.txt")
    );
    assert_eq!(repo.read("new/made.txt").as_deref(), Some("made\n"));
    assert_eq!(repo.read("keep.txt"), None);
}

#[test]
fn undo_refuses_after_a_commit() {
    let repo = Repo::new("undo-moved");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    repo.git(&["add", "-A"]);
    repo.commit("later");

    assert_eq!(refused(repo.undo(&restored.op_id)), Refusal::HeadMoved);
}

/// A file made where the undo puts a directory back, plain or ignored, is
/// not written over; no ref holds it.
#[test]
fn undo_refuses_to_write_over_a_file_where_a_directory_goes() {
    for is_ignored in [false, true] {
        let repo = Repo::new("undo-in-the-way");
        let turn = busy_turn(&repo);
        let restored = finished(repo.restore(&turn));
        assert!(!repo.path.join("new").exists());
        if is_ignored {
            fs::write(repo.path.join(".git/info/exclude"), "new\n").unwrap();
        }
        repo.write("new", "by hand\n");

        assert_eq!(
            refused(repo.undo(&restored.op_id)),
            Refusal::PathsInTheWay {
                paths: vec!["new".to_owned()]
            }
        );
        assert_eq!(repo.read("new").as_deref(), Some("by hand\n"));
    }
}

/// A rollback a prompt stopped leaves a partial restore, and its undo
/// keeps the edit the restore kept.
#[test]
fn a_partial_restore_with_a_kept_edit_is_undone_around_it() {
    let repo = Repo::new("partial-undo");
    let turn = busy_turn(&repo);
    let journal = restore_meeting(&repo, &turn, |repo| {
        repo.write("a.txt", "editor\n");
        place_waiting_marker(repo);
    });
    let RestoreStage::PartiallyApplied { reason, kept, .. } = &journal.stage else {
        panic!("{:?}", journal.stage);
    };
    assert_eq!(*reason, StageReason::AgentStarted);
    assert_eq!(kept, &["a.txt"]);
    fs::remove_dir_all(repo.worktree().git_dir.join("limpid/worktree.lock.waiting")).unwrap();

    let undo = finished(repo.undo(&journal.op_id));

    assert_eq!(undo.stage, RestoreStage::Applied);
    assert_eq!(repo.read("a.txt").as_deref(), Some("editor\n"));
    assert_eq!(repo.read("keep.txt"), None);
    assert_eq!(repo.read("new/made.txt").as_deref(), Some("made\n"));
}

/// The tree a partly applied restore recorded is the only thing that holds
/// the edit it kept, and its undo reads it: `git gc` leaves it while the
/// record is there.
#[test]
fn a_partial_restore_is_undone_after_gc() {
    let repo = Repo::new("partial-gc");
    let turn = busy_turn(&repo);
    let journal = restore_meeting(&repo, &turn, |repo| {
        repo.write("a.txt", "editor\n");
        place_waiting_marker(repo);
    });
    let RestoreStage::PartiallyApplied { current_tree, .. } = &journal.stage else {
        panic!("{:?}", journal.stage);
    };
    fs::remove_dir_all(repo.worktree().git_dir.join("limpid/worktree.lock.waiting")).unwrap();

    collect_garbage(&repo);

    assert!(
        repo.git_status(&["cat-file", "-e", &format!("{current_tree}^{{tree}}")])
            .is_some()
    );
    let undo = finished(repo.undo(&journal.op_id));
    assert_eq!(undo.stage, RestoreStage::Applied);
    assert_eq!(repo.read("a.txt").as_deref(), Some("editor\n"));
    assert_eq!(repo.read("keep.txt"), None);
    assert_eq!(repo.read("new/made.txt").as_deref(), Some("made\n"));
}
