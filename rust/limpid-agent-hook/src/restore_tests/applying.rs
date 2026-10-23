//! Restoring a turn: what is verified and refused before anything is
//! written, and what the restore leaves when another writer meets it.

use super::*;

#[test]
fn verify_recaptures_worktree_and_checks_planned_paths() {
    let repo = Repo::new("applied");
    let turn = busy_turn(&repo);

    let journal = finished(repo.restore(&turn));

    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(journal.turn_number, Some(1));
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));
    assert_eq!(repo.read("keep.txt").as_deref(), Some("keep\n"));
    assert_eq!(repo.read("new/made.txt"), None);
    assert!(
        !repo.path.join("new").exists(),
        "the emptied directory goes too"
    );
    assert_eq!(journal.recorded_untracked, ["new/made.txt"]);
    assert_eq!(
        repo.git(&["rev-parse", &restore_undo_ref(&journal.op_id)]),
        journal.before_tree
    );
}

#[test]
fn restore_leaves_the_real_index_intact() {
    let repo = Repo::new("index");
    let turn = busy_turn(&repo);
    repo.write("a.txt", "a\nstaged\n");
    repo.git(&["add", "a.txt"]);
    let staged = repo.git(&["diff", "--cached", "--name-only"]);
    let index = fs::read(repo.path.join(".git/index")).unwrap();

    let journal = finished(repo.restore(&turn));

    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(fs::read(repo.path.join(".git/index")).unwrap(), index);
    assert_eq!(repo.git(&["diff", "--cached", "--name-only"]), staged);
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));
}

#[test]
fn restore_journals_before_writing() {
    let repo = Repo::new("journal");
    let turn = busy_turn(&repo);
    // A hook that starts waiting once the journal is written stops the
    // restore before its first path: the journal is all there is.
    let seams = Seams {
        after_journal: &|| place_waiting_marker(&repo),
        after_write: &nothing,
        in_write: &nothing_at,
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
            reason: StageReason::AgentStarted
        }
    );
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\nchanged\n"));
    let on_disk = repo.worktree().journal(&journal.op_id).unwrap().unwrap();
    assert_eq!(on_disk.expected_after_tree, journal.expected_after_tree);
    assert_eq!(
        on_disk
            .planned_paths
            .iter()
            .map(|change| (change.path.as_str(), change.kind))
            .collect::<Vec<_>>(),
        [
            ("new/made.txt", PathChangeKind::Delete),
            ("a.txt", PathChangeKind::Modify),
            ("keep.txt", PathChangeKind::Add),
        ]
    );
    // Nothing is left to undo, so nothing pins the tree.
    assert!(
        repo.git_status(&[
            "rev-parse",
            "-q",
            "--verify",
            &restore_undo_ref(&journal.op_id)
        ])
        .is_none()
    );
}

#[test]
fn a_hook_waiting_before_the_plan_is_written_stops_it() {
    let repo = Repo::new("asked");
    let turn = busy_turn(&repo);
    place_waiting_marker(&repo);

    assert_eq!(refused(repo.restore(&turn)), Refusal::AgentStarted);
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\nchanged\n"));
}

#[test]
fn restore_rereads_records_after_lock() {
    let repo = Repo::new("agent");
    let turn = busy_turn(&repo);
    // The prompt makes the run's record say it is running in this worktree.
    repo.hook(
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"again","cwd":"{}"}}"#,
            repo.path.display()
        )
        .as_bytes(),
    );

    assert_eq!(
        refused(repo.restore(&turn)),
        Refusal::AgentActive {
            provider: "claude".to_owned()
        }
    );
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\nchanged\n"));
}

#[test]
fn restore_refuses_in_merge() {
    let repo = Repo::new("merge");
    let turn = busy_turn(&repo);
    let head = repo.git(&["rev-parse", "HEAD"]);
    fs::write(repo.path.join(".git/MERGE_HEAD"), format!("{head}\n")).unwrap();

    assert_eq!(refused(repo.restore(&turn)), Refusal::MergeInProgress);
}

#[test]
fn restore_refuses_after_a_commit_or_a_checkout() {
    let repo = Repo::new("moved");
    let turn = busy_turn(&repo);
    repo.git(&["checkout", "-q", "-b", "other"]);
    assert_eq!(refused(repo.restore(&turn)), Refusal::BranchChanged);
    repo.git(&["checkout", "-q", "main"]);
    repo.git(&["add", "-A"]);
    repo.git(&[
        "-c",
        "user.name=fixture",
        "-c",
        "user.email=fixture@example.com",
        "commit",
        "-q",
        "-m",
        "later",
    ]);
    assert_eq!(refused(repo.restore(&turn)), Refusal::HeadMoved);
}

#[test]
fn restore_deletes_only_recorded_untracked() {
    let repo = Repo::new("untracked");
    let turn = busy_turn(&repo);
    // Made after the turn's last snapshot: no turn recorded it.
    repo.write("mine.txt", "by hand\n");

    let journal = finished(repo.restore(&turn));

    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(repo.read("mine.txt").as_deref(), Some("by hand\n"));
    assert_eq!(repo.read("new/made.txt"), None);
    assert!(
        !journal
            .planned_paths
            .iter()
            .any(|change| change.path == "mine.txt")
    );
}

#[test]
fn rename_is_delete_plus_checkout() {
    let repo = Repo::new("rename");
    let turn = repo.turn(|repo| {
        fs::rename(repo.path.join("a.txt"), repo.path.join("b.txt")).unwrap();
    });

    let journal = finished(repo.restore(&turn));

    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));
    assert_eq!(repo.read("b.txt"), None);
    let kinds: Vec<_> = journal
        .planned_paths
        .iter()
        .map(|change| (change.path.as_str(), change.kind))
        .collect();
    assert_eq!(
        kinds,
        [
            ("b.txt", PathChangeKind::Delete),
            ("a.txt", PathChangeKind::Add)
        ]
    );
}

/// Another writer's edit of a planned path stops the restore whole: what
/// the restore wrote elsewhere goes back, and nothing of it is left, so
/// there is nothing to undo either.
#[test]
fn external_edit_of_planned_path_is_detected() {
    let repo = Repo::new("edited");
    let turn = busy_turn(&repo);

    let journal = restore_meeting(&repo, &turn, |repo| repo.write("a.txt", "editor\n"));

    assert_eq!(
        journal.stage,
        RestoreStage::Aborted {
            reason: StageReason::ExternalChangeDetected
        }
    );
}

#[test]
fn rollback_keeps_externally_edited_planned_paths() {
    let repo = Repo::new("rollback");
    let turn = busy_turn(&repo);

    let _ = restore_meeting(&repo, &turn, |repo| repo.write("a.txt", "editor\n"));

    // The editor's write stays; what the restore wrote elsewhere goes back.
    assert_eq!(repo.read("a.txt").as_deref(), Some("editor\n"));
    assert_eq!(repo.read("keep.txt"), None);
    assert_eq!(repo.read("new/made.txt").as_deref(), Some("made\n"));
}

/// A change outside the planned paths is not the restore's: it neither
/// stops the restore nor is touched by it.
#[test]
fn a_change_outside_the_planned_paths_is_left_alone() {
    let repo = Repo::new("outside");
    let turn = busy_turn(&repo);

    let journal = restore_meeting(&repo, &turn, |repo| repo.write("other.txt", "outside\n"));

    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(repo.read("other.txt").as_deref(), Some("outside\n"));
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));
}

#[test]
fn restore_refuses_while_a_conflict_is_resolved() {
    let repo = Repo::new("conflict");
    let turn = busy_turn(&repo);
    // An unmerged entry with no merge head, as `stash pop` leaves one.
    let blob = repo.git(&["hash-object", "-w", "a.txt"]);
    repo.git_with_input(
        &["update-index", "--index-info"],
        format!("100644 {blob} 1\tc.txt\n100644 {blob} 2\tc.txt\n").as_bytes(),
    );

    assert_eq!(refused(repo.restore(&turn)), Refusal::MergeInProgress);
}

/// Files the capture could not see are not written over.
#[test]
fn restore_refuses_to_write_over_ignored_or_large_files() {
    let repo = Repo::new("ignored");
    repo.write("secret.env", "v1\n");
    repo.write("big.bin", "small\n");
    let turn = repo.turn(|repo| {
        repo.write(".gitignore", "secret.env\n");
        repo.write("secret.env", "v2\n");
        repo.write(
            "big.bin",
            &"x".repeat(usize::try_from(crate::LARGE_FILE_BYTES).unwrap() + 1),
        );
    });

    assert_eq!(
        refused(repo.restore(&turn)),
        Refusal::PathsInTheWay {
            paths: vec!["big.bin".to_owned(), "secret.env".to_owned()]
        }
    );
    assert_eq!(repo.read("secret.env").as_deref(), Some("v2\n"));
}

/// A file made by hand where a restored directory goes is in the way: the
/// restore is refused, and the file keeps what it holds.
#[test]
fn restore_refuses_to_replace_a_file_with_a_directory() {
    let repo = Repo::new("dir-file");
    repo.write("d/f.txt", "f\n");
    let turn = repo.turn(|repo| {
        fs::remove_dir_all(repo.path.join("d")).unwrap();
    });
    repo.write("d", "by hand\n");

    assert_eq!(
        refused(repo.restore(&turn)),
        Refusal::PathsInTheWay {
            paths: vec!["d".to_owned()]
        }
    );
    assert_eq!(repo.read("d").as_deref(), Some("by hand\n"));
}

/// A turn that ignored what it made: once the restore takes the
/// `.gitignore` away, those files show, but they are not the restore's and
/// do not stop it.
#[test]
fn a_gitignore_the_restore_removes_does_not_stop_it() {
    let repo = Repo::new("gitignore");
    let turn = repo.turn(|repo| {
        repo.write(".gitignore", "*.log\n");
        repo.write("x.log", "log\n");
    });

    let journal = finished(repo.restore(&turn));

    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(repo.read(".gitignore"), None);
    assert_eq!(repo.read("x.log").as_deref(), Some("log\n"));
}

/// A name an earlier turn made, made again by hand after the restored
/// turn, is not the turns' to delete.
#[test]
fn an_untracked_file_an_earlier_turn_made_is_not_deleted() {
    let repo = Repo::new("earlier");
    let _ = repo.turn(|repo| repo.write("notes.txt", "turn\n"));
    fs::remove_file(repo.path.join("notes.txt")).unwrap();
    let turn = repo.turn(|repo| repo.write("a.txt", "a\nchanged\n"));
    repo.write("notes.txt", "by hand\n");

    let journal = finished(repo.restore(&turn));

    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(repo.read("notes.txt").as_deref(), Some("by hand\n"));
}

#[test]
fn an_agent_whose_process_is_gone_does_not_keep_the_restore_back() {
    let repo = Repo::new("gone");
    let turn = busy_turn(&repo);
    let mut child = std::process::Command::new("/bin/sleep")
        .arg("30")
        .spawn()
        .unwrap();
    let pid = child.id();
    child.kill().unwrap();
    child.wait().unwrap();
    let record = format!(
        r#"{{"schemaVersion":3,"paneId":"P2","runId":"R2","revision":1,"state":"running","updatedAt":"{NOW}","pid":"{pid}","worktreeRoot":"{}"}}"#,
        repo.path.display()
    );
    fs::write(repo.states.join("R2.state.json"), record).unwrap();

    assert_eq!(finished(repo.restore(&turn)).stage, RestoreStage::Applied);
}

#[test]
fn an_agent_of_the_worktree_without_a_snapshot_keeps_the_restore_back() {
    let repo = Repo::new("no-snapshot");
    let turn = busy_turn(&repo);
    let record = format!(
        r#"{{"schemaVersion":3,"paneId":"P2","runId":"R2","revision":1,"state":"running","updatedAt":"{NOW}","worktreeRoot":"{}"}}"#,
        repo.path.display()
    );
    fs::write(repo.states.join("R2.state.json"), record).unwrap();

    assert_eq!(
        refused(repo.restore(&turn)),
        Refusal::AgentActive {
            provider: "claude".to_owned()
        }
    );
}

/// Names a shell or a pathspec would read otherwise, and a link.
#[test]
fn awkward_names_and_links_are_restored() {
    let repo = Repo::new("names");
    let names = ["a b.txt", "*.txt", "-x", "new\nline", "e\u{301}.txt"];
    for name in names {
        repo.write(name, "before\n");
    }
    std::os::unix::fs::symlink("a.txt", repo.path.join("link")).unwrap();
    let turn = repo.turn(|repo| {
        for name in names {
            repo.write(name, "after\n");
        }
        fs::remove_file(repo.path.join("link")).unwrap();
        std::os::unix::fs::symlink("keep.txt", repo.path.join("link")).unwrap();
    });

    let journal = finished(repo.restore(&turn));

    assert_eq!(journal.stage, RestoreStage::Applied);
    for name in names {
        assert_eq!(repo.read(name).as_deref(), Some("before\n"), "{name:?}");
    }
    assert_eq!(
        fs::read_link(repo.path.join("link")).unwrap(),
        PathBuf::from("a.txt")
    );
}

/// The rollback after another writer's edit does not write over a file
/// that writer made where a directory goes back: that path keeps what the
/// restore wrote, and says why.
#[test]
fn rollback_leaves_a_file_where_a_directory_goes() {
    let repo = Repo::new("rollback-in-the-way");
    let turn = busy_turn(&repo);

    let journal = restore_meeting(&repo, &turn, |repo| {
        repo.write("a.txt", "editor\n");
        repo.write("new", "editor\n");
    });

    let RestoreStage::PartiallyApplied { kept, failed, .. } = &journal.stage else {
        panic!("{:?}", journal.stage);
    };
    assert_eq!(kept, &["a.txt"]);
    assert_eq!(
        failed,
        &[FailedPath {
            path: "new/made.txt".to_owned(),
            reason: FailedReason::InTheWay,
            detail: None,
        }]
    );
    assert_eq!(repo.read("new").as_deref(), Some("editor\n"));
    assert_eq!(repo.read("keep.txt"), None, "what could go back did");
}

/// A turn that made a file a directory is restored, and undone.
#[test]
fn a_file_the_turn_made_a_directory_is_restored() {
    let repo = Repo::new("file-to-dir");
    repo.write("d", "file\n");
    let turn = repo.turn(|repo| {
        fs::remove_file(repo.path.join("d")).unwrap();
        repo.write("d/f.txt", "in dir\n");
    });

    let restored = finished(repo.restore(&turn));

    assert_eq!(restored.stage, RestoreStage::Applied);
    assert_eq!(repo.read("d").as_deref(), Some("file\n"));
    let undo = finished(repo.undo(&restored.op_id));
    assert_eq!(undo.stage, RestoreStage::Applied);
    assert_eq!(repo.read("d/f.txt").as_deref(), Some("in dir\n"));
}

/// A turn that made a directory a file, restored while an editor
/// writes elsewhere: the rollback puts the turn's file back whole.
#[test]
fn a_rollback_puts_back_a_file_the_restore_made_a_directory() {
    let repo = Repo::new("dir-to-file");
    repo.write("d/f.txt", "in dir\n");
    let turn = repo.turn(|repo| {
        fs::remove_dir_all(repo.path.join("d")).unwrap();
        repo.write("d", "file now\n");
        repo.write("a.txt", "a\nchanged\n");
    });

    let journal = restore_meeting(&repo, &turn, |repo| repo.write("a.txt", "editor\n"));

    assert_eq!(
        journal.stage,
        RestoreStage::Aborted {
            reason: StageReason::ExternalChangeDetected
        }
    );
    assert_eq!(repo.read("d").as_deref(), Some("file now\n"));
    assert_eq!(repo.read("a.txt").as_deref(), Some("editor\n"));

    // Without the editor, it is restored and undone.
    let restored = finished(repo.restore(&turn));
    assert_eq!(restored.stage, RestoreStage::Applied);
    assert_eq!(repo.read("d/f.txt").as_deref(), Some("in dir\n"));
    let undo = finished(repo.undo(&restored.op_id));
    assert_eq!(undo.stage, RestoreStage::Applied);
    assert_eq!(repo.read("d").as_deref(), Some("file now\n"));
}

/// An editor's save between the plan and the write is not written over:
/// each path is read again just before its batch.
#[test]
fn a_save_after_the_plan_is_not_written_over() {
    let repo = Repo::new("saved");
    let turn = busy_turn(&repo);
    let seams = Seams {
        after_journal: &|| repo.write("a.txt", "saved meanwhile\n"),
        after_write: &nothing,
        in_write: &nothing_at,
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
    assert_eq!(repo.read("a.txt").as_deref(), Some("saved meanwhile\n"));
    assert_eq!(repo.read("new/made.txt").as_deref(), Some("made\n"));
}

/// A stop that leaves a path holding neither what was there nor what the
/// restore writes is not "nothing happened": the start stays pinned and
/// recorded.
#[test]
fn a_stop_with_a_path_holding_neither_side_is_partly_applied() {
    let repo = Repo::new("neither");
    let turn = busy_turn(&repo);
    let seams = Seams {
        after_journal: &|| {
            repo.write("a.txt", "half written\n");
            place_waiting_marker(&repo);
        },
        after_write: &nothing,
        in_write: &nothing_at,
        in_rollback: &nothing_at,
    };

    let journal = finished(outcome(restore_turn_inner(
        &repo.request(&turn),
        NOW,
        &seams,
    )));

    let RestoreStage::PartiallyApplied { kept, .. } = &journal.stage else {
        panic!("{:?}", journal.stage);
    };
    assert_eq!(kept, &["a.txt"]);
    assert!(
        repo.git_status(&[
            "rev-parse",
            "-q",
            "--verify",
            &restore_undo_ref(&journal.op_id)
        ])
        .is_some()
    );
}

/// A file marked assume-unchanged is read as it is on disk: its content is
/// what the undo brings back, not the index's.
#[test]
fn an_assumed_unchanged_file_is_read_from_disk() {
    let repo = Repo::new("assumed");
    let turn = busy_turn(&repo);
    repo.write("a.txt", "staged\n");
    repo.git(&["add", "a.txt"]);
    repo.git(&["update-index", "--assume-unchanged", "a.txt"]);
    repo.write("a.txt", "only on disk\n");

    let restored = finished(repo.restore(&turn));
    assert_eq!(restored.stage, RestoreStage::Applied);
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));
    let undo = finished(repo.undo(&restored.op_id));

    assert_eq!(undo.stage, RestoreStage::Applied);
    assert_eq!(repo.read("a.txt").as_deref(), Some("only on disk\n"));
}

/// An edit made before the turn to a file marked assume-unchanged is in
/// the turn's start, so a restore to it leaves the edit: the turn's
/// snapshot reads the file from disk, as the restore's own capture does.
#[test]
fn an_edit_before_the_turn_to_an_assumed_unchanged_file_stays() {
    let repo = Repo::new("assumed-before");
    repo.git(&["update-index", "--assume-unchanged", "a.txt"]);
    repo.write("a.txt", "edited before the turn\n");
    let turn = repo.turn(|repo| repo.write("keep.txt", "keep\nchanged\n"));

    let restored = finished(repo.restore(&turn));

    assert_eq!(restored.stage, RestoreStage::Applied);
    assert_eq!(
        restored
            .planned_paths
            .iter()
            .map(|change| change.path.as_str())
            .collect::<Vec<_>>(),
        ["keep.txt"]
    );
    assert_eq!(repo.read("keep.txt").as_deref(), Some("keep\n"));
    assert_eq!(
        repo.read("a.txt").as_deref(),
        Some("edited before the turn\n")
    );
    // The real index keeps its mark: only the private copies lost theirs.
    assert!(repo.git(&["ls-files", "-v", "a.txt"]).starts_with("h "));
}

/// A smudge filter that never answers holds the restore's checkout only
/// until git's limit: the restore then ends as a failed write ends, its
/// journal left for the next operation to settle, and the worktree's lock
/// is free again.
#[test]
fn a_filter_that_never_answers_ends_the_restore_at_the_limit() {
    let repo = Repo::new("hung-filter");
    let turn = busy_turn(&repo);
    repo.git(&["config", "filter.hang.clean", "cat"]);
    repo.git(&["config", "filter.hang.smudge", "sleep 30"]);
    repo.write(".gitattributes", "a.txt filter=hang\n");
    crate::git::limit_commands_for_test(Duration::from_millis(500));

    let started = std::time::Instant::now();
    let journal = finished(repo.restore(&turn));

    assert!(started.elapsed() < Duration::from_secs(10));
    assert!(journal.stage.is_interrupted(), "{:?}", journal.stage);
    let worktree = repo.worktree();
    assert_eq!(
        worktree
            .journal(&journal.op_id)
            .unwrap()
            .map(|kept| kept.stage),
        Some(journal.stage.clone())
    );
    let (refs, has_refs_file) = held(&repo, &journal.op_id);
    assert!(!refs.is_empty() && has_refs_file, "the trees stay pinned");

    // With the filter answering again, the next operation settles it.
    repo.git(&["config", "filter.hang.smudge", "cat"]);
    let _ = recover(&repo.path, NOW).unwrap();
    assert!(
        !worktree
            .journal(&journal.op_id)
            .unwrap()
            .unwrap()
            .stage
            .is_interrupted()
    );
}

#[test]
fn a_sparse_checkout_is_refused() {
    let repo = Repo::new("sparse");
    let turn = busy_turn(&repo);
    repo.git(&["update-index", "--skip-worktree", "keep.txt"]);

    assert_eq!(refused(repo.restore(&turn)), Refusal::SparseCheckout);
}

/// The deletions that empty a directory fill a whole batch, and the
/// file that takes the directory's place is written in the next: the
/// emptied directory is the restore's own doing, not another writer's.
#[test]
fn a_directory_emptied_by_an_earlier_batch_is_not_another_writers() {
    let repo = Repo::new("batch-edge");
    repo.write("d", "file\n");
    let turn = repo.turn(|repo| {
        fs::remove_file(repo.path.join("d")).unwrap();
        for number in 0..WRITE_BATCH {
            repo.write(&format!("d/{number:02}.txt"), "in dir\n");
        }
    });

    let journal = finished(repo.restore(&turn));

    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(repo.read("d").as_deref(), Some("file\n"));
}

#[test]
fn a_turn_of_another_worktree_or_unknown_id_is_refused() {
    let repo = Repo::new("other");
    let other = Repo::new("other-2");
    let turn = busy_turn(&other);
    let mut request = repo.request(&turn);
    request.state_directories[0].directory = other.states.clone();
    assert_eq!(refused(restore_turn(&request, NOW)), Refusal::OtherWorktree);
    assert_eq!(refused(repo.restore("not-a-turn")), Refusal::TurnNotFound);
}

/// A name that changed only in case, on a volume that does not tell case
/// apart, is one file under both names, which git reads through one index
/// entry: the restore is refused, and nothing is written.
#[test]
fn a_rename_only_in_case_is_refused_where_case_is_one_name() {
    let repo = Repo::new("case");
    repo.write("Name.txt", "name\n");
    repo.git(&["add", "Name.txt"]);
    repo.commit("name");
    let turn = repo.turn(|repo| {
        repo.git(&["mv", "Name.txt", "name.txt"]);
    });
    let is_one_name = fs::symlink_metadata(repo.path.join("Name.txt")).is_ok();

    let outcome = repo.restore(&turn);

    if is_one_name {
        assert_eq!(
            refused(outcome),
            Refusal::RenamedInPlace {
                paths: vec!["Name.txt".to_owned()]
            }
        );
        assert!(
            fs::read_dir(&repo.path)
                .unwrap()
                .flatten()
                .any(|entry| entry.file_name() == "name.txt")
        );
    } else {
        assert_eq!(finished(outcome).stage, RestoreStage::Applied);
    }
}
