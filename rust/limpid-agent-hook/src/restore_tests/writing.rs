//! Writing one path through the swap without losing another writer's save.

use super::*;

/// One change of `path` to what HEAD holds there (a deletion when `kind`
/// says so), for driving the writer directly.
fn change_to_head(repo: &Repo, path: &str, kind: PathChangeKind) -> Change {
    let object = if kind == PathChangeKind::Delete {
        String::new()
    } else {
        repo.git(&["rev-parse", &format!("HEAD:{path}")])
    };
    Change {
        raw: path.as_bytes().to_vec(),
        display: path.to_owned(),
        kind,
        mode: "100644".to_owned(),
        object,
    }
}

/// A save that lands after git read a path and before the path is
/// swapped comes out of the swap, and goes back: nothing is written over
/// unseen. The same for a path the operation deletes.
#[test]
fn a_save_between_the_read_and_the_swap_is_put_back() {
    let repo = Repo::new("swap-race");
    repo.write("a.txt", "changed\n");
    let worktree = repo.worktree();
    let before = worktree.capture("race-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let save = |moment| {
        if moment == Moment::AfterRead {
            repo.write("a.txt", "the editor's, longer\n");
        }
    };

    let mut writer = Writer::new(&worktree, "RACE", &head, "target")
        .unwrap()
        .with_between(&save);
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    assert!(writer.finish().is_empty());

    assert_eq!(results[0].1, Err(Unwritten::ChangedWhileWriting));
    assert_eq!(
        repo.read("a.txt").as_deref(),
        Some("the editor's, longer\n")
    );

    // Read again, unchanged since: written.
    let before = worktree.capture("race-before-2").unwrap();
    let mut writer = Writer::new(&worktree, "RACE2", &head, "target").unwrap();
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    assert!(writer.finish().is_empty());
    assert_eq!(results[0].1, Ok(()));
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));

    // A deletion read, then saved over: the save stays.
    let before = worktree.capture("race-before-3").unwrap();
    let save_keep = |moment| {
        if moment == Moment::AfterRead {
            repo.write("keep.txt", "saved after the read\n");
        }
    };
    let mut writer = Writer::new(&worktree, "RACE3", &head, "target")
        .unwrap()
        .with_between(&save_keep);
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "keep.txt", PathChangeKind::Delete)],
    );
    assert!(writer.finish().is_empty());
    assert_eq!(results[0].1, Err(Unwritten::ChangedWhileWriting));
    assert_eq!(
        repo.read("keep.txt").as_deref(),
        Some("saved after the read\n")
    );
    assert!(
        !worktree.staging("RACE3").exists(),
        "nothing left in the worktree"
    );
}

/// A write through a descriptor opened before the swap lands in the file
/// that came out; it is kept aside, not deleted, and the journal says
/// where.
#[test]
fn a_write_to_the_file_that_came_out_is_kept_aside() {
    let repo = Repo::new("swap-late");
    repo.write("a.txt", "changed\n");
    let worktree = repo.worktree();
    let before = worktree.capture("late-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);

    let mut writer = Writer::new(&worktree, "LATE", &head, "target").unwrap();
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    assert_eq!(results[0].1, Ok(()));
    let came_out = worktree.staging("LATE").join("target/ready-1/a.txt");
    fs::write(&came_out, "written late through an old descriptor\n").unwrap();
    let kept = writer.finish();

    assert_eq!(kept.len(), 1);
    assert_eq!(kept[0].path, "a.txt");
    assert!(kept[0].kept_at().is_some(), "{kept:?}");
    assert_eq!(
        fs::read_to_string(&came_out).unwrap(),
        "written late through an old descriptor\n"
    );
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));
}

/// A save after the read comes out of the swap; one more save on top of
/// what was swapped in, before it goes back, is not written over either:
/// the first is kept aside, and the path keeps the last.
#[test]
fn a_save_on_top_of_the_swap_keeps_the_earlier_save_aside() {
    let repo = Repo::new("swap-twice");
    repo.write("a.txt", "changed\n");
    let worktree = repo.worktree();
    let before = worktree.capture("twice-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let saves = |moment| match moment {
        Moment::AfterRead => repo.write("a.txt", "first save\n"),
        Moment::AfterSwap => repo.write("a.txt", "second save, longer\n"),
        Moment::AtFinish => {}
    };

    let mut writer = Writer::new(&worktree, "TWICE", &head, "target")
        .unwrap()
        .with_between(&saves);
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    let kept = writer.finish();

    let aside = ".limpid-TWICE/target/ready-1/a.txt";
    assert_eq!(results[0].1, Err(Unwritten::KeptAside(aside.to_owned())));
    assert_eq!(kept.len(), 1);
    assert_eq!(repo.read("a.txt").as_deref(), Some("second save, longer\n"));
    assert_eq!(repo.read(aside).as_deref(), Some("first save\n"));
    // Git does not see what the staging area keeps.
    assert_eq!(
        repo.git(&["status", "--porcelain", "--", ".limpid-TWICE"]),
        ""
    );
}

/// A save into a file the rollback took out keeps the restore from being
/// called aborted: the record says where the save went.
#[test]
fn a_save_kept_aside_in_the_rollback_leaves_the_restore_partial() {
    let repo = Repo::new("rollback-aside");
    let turn = repo.turn(|repo| {
        repo.write("a.txt", "a\nchanged\n");
        repo.write("keep.txt", "keep\nchanged\n");
    });
    let parked = repo.path.join(".limpid-ASIDE");
    let late = |moment| {
        if moment == Moment::AtFinish {
            // The file the rollback took out of keep.txt, wherever its
            // operation put it.
            for entry in fs::read_dir(&repo.path).unwrap().flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with(".limpid-") {
                    let file = entry.path().join("back/ready-1/keep.txt");
                    if file.exists() {
                        fs::write(file, "written late\n").unwrap();
                    }
                }
            }
        }
    };
    let seams = Seams {
        after_journal: &nothing,
        after_write: &|| repo.write("a.txt", "editor\n"),
        in_write: &nothing_at,
        in_rollback: &late,
    };

    let journal = finished(outcome(restore_turn_inner(
        &repo.request(&turn),
        NOW,
        &seams,
    )));

    let RestoreStage::PartiallyApplied { kept, failed, .. } = &journal.stage else {
        panic!("{:?}", journal.stage);
    };
    assert_eq!(kept, &["a.txt"]);
    assert!(
        failed
            .iter()
            .any(|failed| failed.path == "keep.txt" && failed.kept_at().is_some()),
        "{failed:?}"
    );
    assert!(!parked.exists());
    assert_eq!(repo.read("keep.txt").as_deref(), Some("keep\nchanged\n"));
}

/// A save found while writing stops the restore as one found after it
/// does: what the restore wrote elsewhere goes back, and nothing is left
/// half done.
#[test]
fn a_save_found_while_writing_takes_the_restore_back_whole() {
    let repo = Repo::new("found-while-writing");
    let turn = busy_turn(&repo);
    let save = |moment| {
        if moment == Moment::AfterRead && repo.read("a.txt").as_deref() == Some("a\nchanged\n") {
            repo.write("a.txt", "saved while writing\n");
        }
    };
    let seams = Seams {
        after_journal: &nothing,
        after_write: &nothing,
        in_write: &save,
        in_rollback: &nothing_at,
    };

    let journal = finished(outcome(restore_turn_inner(
        &repo.request(&turn),
        NOW,
        &seams,
    )));

    assert_eq!(
        journal.stage,
        RestoreStage::Aborted {
            reason: StageReason::ExternalChangeDetected
        }
    );
    assert_eq!(repo.read("a.txt").as_deref(), Some("saved while writing\n"));
    assert_eq!(repo.read("keep.txt"), None);
    assert_eq!(repo.read("new/made.txt").as_deref(), Some("made\n"));
}

/// An exchange the system refuses (a locked file) writes nothing and
/// leaves nothing: the path keeps its file, and no made file is taken for
/// another writer's save.
#[cfg(target_os = "macos")]
#[test]
fn a_refused_exchange_leaves_the_path_and_no_save_aside() {
    let repo = Repo::new("swap-refused");
    repo.write("a.txt", "changed\n");
    let worktree = repo.worktree();
    let before = worktree.capture("refused-before").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let lock = |flag: &str| {
        let status = Command::new("chflags")
            .args([flag, &repo.path.join("a.txt").to_string_lossy()])
            .status()
            .unwrap();
        assert!(status.success());
    };
    lock("uchg");

    let mut writer = Writer::new(&worktree, "REFUSED", &head, "target").unwrap();
    let results = writer.write(
        &before,
        &[change_to_head(&repo, "a.txt", PathChangeKind::Modify)],
    );
    let kept = writer.finish();
    lock("nouchg");

    assert!(
        results[0]
            .1
            .as_ref()
            .is_err_and(|unwritten| !matches!(unwritten, Unwritten::KeptAside(_))),
        "{results:?}"
    );
    assert!(kept.is_empty(), "{kept:?}");
    assert_eq!(repo.read("a.txt").as_deref(), Some("changed\n"));
    assert!(!worktree.staging("REFUSED").exists());
}

/// A save git reads the same as the restore's file (`ident` folds any
/// `$Id: ... $`) is still another writer's: when the rollback takes it
/// out, no tree gives its bytes back, so it is kept aside, not deleted.
#[test]
fn a_save_a_filter_reads_as_the_same_is_kept_aside() {
    let repo = Repo::new("ident");
    repo.write(".gitattributes", "a.txt ident\n");
    repo.write("a.txt", "$Id$\nline\n");
    repo.git(&["add", ".gitattributes", "a.txt"]);
    repo.commit("ident");
    let turn = repo.turn(|repo| {
        repo.write("a.txt", "$Id$\nchanged\n");
        repo.write("keep.txt", "keep\nchanged\n");
    });
    let seams = Seams {
        after_journal: &nothing,
        after_write: &|| {
            // Read by git as the restore's own file, and it is not.
            repo.write("a.txt", "$Id: the editor's own $\nline\n");
            repo.write("keep.txt", "editor\n");
        },
        in_write: &nothing_at,
        in_rollback: &nothing_at,
    };

    let journal = finished(outcome(restore_turn_inner(
        &repo.request(&turn),
        NOW,
        &seams,
    )));

    let RestoreStage::PartiallyApplied { failed, .. } = &journal.stage else {
        panic!("{:?}", journal.stage);
    };
    let aside = failed
        .iter()
        .find(|failed| failed.path == "a.txt")
        .and_then(FailedPath::kept_at)
        .unwrap_or_else(|| panic!("{failed:?}"));
    assert_eq!(
        repo.read(aside).as_deref(),
        Some("$Id: the editor's own $\nline\n")
    );
}

/// A restore whole but for a save it kept aside is done; once undone, the
/// save stays where it went, and the undo's record names it.
#[test]
fn a_save_kept_aside_is_named_by_the_undo_too() {
    let repo = Repo::new("aside-undo");
    let turn = busy_turn(&repo);
    let late = |moment| {
        if moment == Moment::AtFinish {
            for entry in fs::read_dir(&repo.path).unwrap().flatten() {
                if entry.file_name().to_string_lossy().starts_with(".limpid-") {
                    let file = entry.path().join("target/ready-1/a.txt");
                    if file.exists() {
                        fs::write(file, "written late\n").unwrap();
                    }
                }
            }
        }
    };
    let seams = Seams {
        after_journal: &nothing,
        after_write: &nothing,
        in_write: &late,
        in_rollback: &nothing_at,
    };
    let restored = finished(outcome(restore_turn_inner(
        &repo.request(&turn),
        NOW,
        &seams,
    )));
    let RestoreStage::PartiallyApplied { reason, failed, .. } = &restored.stage else {
        panic!("{:?}", restored.stage);
    };
    assert_eq!(*reason, StageReason::KeptAside);
    let place = failed[0].kept_at().unwrap().to_owned();

    let undo = finished(repo.undo(&restored.op_id));

    let RestoreStage::PartiallyApplied { reason, failed, .. } = &undo.stage else {
        panic!("{:?}", undo.stage);
    };
    assert_eq!(*reason, StageReason::KeptAside);
    assert!(
        failed.iter().any(|failed| failed.kept_at() == Some(&place)),
        "{failed:?}"
    );
    assert!(matches!(
        repo.worktree()
            .journal(&restored.op_id)
            .unwrap()
            .unwrap()
            .stage,
        RestoreStage::Undone { .. }
    ));

    // A crash after the undo's journal and before the marks: recovery
    // marks the restore, and the undo names the saves.
    let worktree = repo.worktree();
    let mut bare = undo.clone();
    bare.stage = RestoreStage::Applied;
    assert!(worktree.write_journal(&bare).is_ok());
    assert!(worktree.write_journal(&restored).is_ok());
    let _ = recover(&repo.path, NOW).unwrap();
    let undo = worktree.journal(&undo.op_id).unwrap().unwrap();
    let RestoreStage::PartiallyApplied { failed, .. } = &undo.stage else {
        panic!("{:?}", undo.stage);
    };
    assert_eq!(
        failed
            .iter()
            .filter(|failed| failed.kept_at() == Some(&place))
            .count(),
        1
    );
    assert!(matches!(
        worktree.journal(&restored.op_id).unwrap().unwrap().stage,
        RestoreStage::Undone { .. }
    ));
}

/// The stage is what the planned paths hold: a write that failed where the
/// path still holds what was there before is no part of a partial restore.
/// A failure is said beside a stage only of a path the operation did not
/// leave as it writes it.
#[test]
fn a_failed_write_is_said_beside_the_stage_the_paths_decide() {
    let change = |path: &str| Change {
        raw: path.as_bytes().to_vec(),
        display: path.to_owned(),
        kind: PathChangeKind::Modify,
        mode: "100644".to_owned(),
        object: "0".repeat(40),
    };
    let reading = |states: &[(&str, PathState)]| Reading {
        paths: states
            .iter()
            .map(|(path, state)| PlannedPath {
                change: change(path),
                state: *state,
                now: None,
                back: change(path),
            })
            .collect(),
        current_tree: "c".repeat(40),
    };
    let failure = |path: &str| FailedPath {
        path: path.to_owned(),
        reason: FailedReason::WriteFailed,
        detail: Some("checkout-index".to_owned()),
    };

    let untouched = reading(&[("a", PathState::Before), ("b", PathState::Before)]);
    assert_eq!(
        settled_stage(&untouched, StageReason::WriteFailed, vec![failure("b")]),
        Some(RestoreStage::Aborted {
            reason: StageReason::WriteFailed
        })
    );

    let half = reading(&[("a", PathState::Target), ("b", PathState::Before)]);
    let Some(RestoreStage::PartiallyApplied { failed, .. }) = settled_stage(
        &half,
        StageReason::WriteFailed,
        vec![failure("a"), failure("b")],
    ) else {
        panic!("not partial");
    };
    assert_eq!(failed, vec![failure("b")]);
}
