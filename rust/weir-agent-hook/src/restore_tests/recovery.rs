//! Recovery after a crash: how an interrupted journal settles, which
//! records are pruned, and what the staging area still holds.

use super::*;

#[test]
fn recover_classifies_interrupted_journal() {
    let repo = Repo::new("recover");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let interrupt = |op: &str| {
        let mut journal = restored.clone();
        journal.op_id = op.to_owned();
        journal.stage = RestoreStage::Writing { done: Vec::new() };
        assert!(worktree.write_journal(&journal).is_ok());
    };
    let ops = [new_op_id(), new_op_id(), new_op_id()];

    // Every planned path as the restore writes it: applied.
    interrupt(&ops[0]);
    let _ = recover(&repo.path, NOW).unwrap();
    assert_eq!(
        worktree.journal(&ops[0]).unwrap().unwrap().stage,
        RestoreStage::Applied
    );

    // None: aborted.
    let _ = finished(repo.undo(&restored.op_id));
    interrupt(&ops[1]);
    let _ = recover(&repo.path, NOW).unwrap();
    assert!(matches!(
        worktree.journal(&ops[1]).unwrap().unwrap().stage,
        RestoreStage::Aborted { .. }
    ));

    // Some: partly applied, with the tree it found.
    repo.write("a.txt", "a\n");
    interrupt(&ops[2]);
    let recovery = recover(&repo.path, NOW).unwrap();
    assert!(matches!(
        worktree.journal(&ops[2]).unwrap().unwrap().stage,
        RestoreStage::PartiallyApplied {
            reason: StageReason::Interrupted,
            ..
        }
    ));
    assert!(
        recovery
            .journals
            .iter()
            .all(|journal| !journal.stage.is_interrupted())
    );
    // The call that settled it says so, once: the person is told once.
    assert_eq!(recovery.settled, [ops[2].clone()]);
    assert!(recover(&repo.path, NOW).unwrap().settled.is_empty());
}

/// An undo a crash cut short, or one whose journal was written before the
/// mark on its restore, is found finished by the next recovery, which marks
/// the restore it undid: that restore is no longer offered.
#[test]
fn recover_marks_the_restore_an_undo_left_unmarked() {
    for undo_stage in [RestoreStage::Verifying, RestoreStage::Applied] {
        let repo = Repo::new("recover-undo");
        let turn = busy_turn(&repo);
        let restored = finished(repo.restore(&turn));
        let undo = finished(repo.undo(&restored.op_id));
        let worktree = repo.worktree();
        let mut cut_short = undo.clone();
        cut_short.stage = undo_stage.clone();
        assert!(worktree.write_journal(&cut_short).is_ok());
        let mut not_marked = restored.clone();
        not_marked.stage = RestoreStage::Applied;
        assert!(worktree.write_journal(&not_marked).is_ok());

        let _ = recover(&repo.path, NOW).unwrap();

        assert_eq!(
            worktree.journal(&undo.op_id).unwrap().unwrap().stage,
            RestoreStage::Applied,
            "{undo_stage:?}"
        );
        assert_eq!(
            worktree.journal(&restored.op_id).unwrap().unwrap().stage,
            RestoreStage::Undone { by: undo.op_id },
            "{undo_stage:?}"
        );
    }
}

/// A restore still to be undone keeps its record however old; one
/// nothing can take back goes after its lifetime, with its ref.
#[test]
fn only_finished_journals_past_their_lifetime_are_dropped() {
    let repo = Repo::new("prune");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let old = "2026-01-01T00:00:00Z";
    let mut applied = restored.clone();
    applied.at = old.to_owned();
    assert!(worktree.write_journal(&applied).is_ok());
    let mut aborted = restored.clone();
    aborted.op_id = new_op_id();
    aborted.at = old.to_owned();
    aborted.stage = RestoreStage::Aborted {
        reason: StageReason::ExternalChangeDetected,
    };
    assert!(worktree.write_journal(&aborted).is_ok());
    repo.git(&[
        "update-ref",
        &restore_undo_ref(&aborted.op_id),
        &aborted.before_tree,
    ]);

    let journals = recover(&repo.path, NOW).unwrap().journals;

    assert_eq!(
        journals
            .iter()
            .map(|journal| journal.op_id.as_str())
            .collect::<Vec<_>>(),
        [restored.op_id.as_str()]
    );
    assert!(
        repo.git_status(&[
            "rev-parse",
            "-q",
            "--verify",
            &restore_undo_ref(&aborted.op_id)
        ])
        .is_none()
    );
    assert!(
        repo.git_status(&[
            "rev-parse",
            "-q",
            "--verify",
            &restore_undo_ref(&restored.op_id)
        ])
        .is_some()
    );
}

/// A crash cuts a restore short; `git gc` runs before the app is back.
/// Recovery still reads the tree the restore meant to leave, which no
/// other ref holds when a file outside the plan was there.
#[test]
fn an_interrupted_restore_is_recovered_after_gc() {
    let repo = Repo::new("recover-gc");
    let turn = busy_turn(&repo);
    repo.write("other.txt", "outside\n");
    let crash = || panic!("crash after the writes");
    let seams = Seams {
        after_journal: &nothing,
        after_write: &crash,
        in_write: &nothing_at,
        in_rollback: &nothing_at,
    };
    let crashed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        restore_turn_inner(&repo.request(&turn), NOW, &seams)
    }));
    assert!(crashed.is_err());
    let (journals, failure) = repo.worktree().readable_journals();
    assert!(failure.is_none(), "{failure:?}");
    let [cut_short] = journals.as_slice() else {
        panic!("{journals:?}");
    };
    assert!(cut_short.stage.is_interrupted());
    assert_ne!(cut_short.expected_after_tree, cut_short.target_tree);

    collect_garbage(&repo);

    let recovery = recover(&repo.path, NOW).unwrap();
    assert_eq!(recovery.settled, std::slice::from_ref(&cut_short.op_id));
    assert_eq!(
        repo.worktree()
            .journal(&cut_short.op_id)
            .unwrap()
            .unwrap()
            .stage,
        RestoreStage::Applied
    );
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\n"));
    assert_eq!(repo.read("other.txt").as_deref(), Some("outside\n"));
}

/// What a crash left in the staging area: a half-made file goes, one that
/// is a path's before or after content goes (a tree holds it), and
/// anything else is another writer's save and stays aside.
#[test]
fn recovery_judges_what_the_staging_area_still_holds() {
    let repo = Repo::new("leftovers");
    let worktree = repo.worktree();
    let staging = worktree.staging("CRASH").join("target");
    fs::create_dir_all(staging.join("gen-2")).unwrap();
    fs::write(staging.join("gen-2/a.txt"), "half").unwrap();
    fs::create_dir_all(staging.join("ready-1")).unwrap();
    fs::write(staging.join("ready-1/a.txt"), "a\n").unwrap();
    fs::write(
        staging.join("ready-1/keep.txt"),
        "a save of nobody's tree\n",
    )
    .unwrap();
    fs::create_dir_all(staging.join("out")).unwrap();
    fs::write(staging.join("out/gone.txt"), "taken out, then saved to\n").unwrap();
    fs::write(worktree.staging("CRASH").join(".gitignore"), "*\n").unwrap();
    let head = repo.git(&["rev-parse", "HEAD^{tree}"]);
    let raws = vec![
        b"a.txt".to_vec(),
        b"keep.txt".to_vec(),
        b"gone.txt".to_vec(),
    ];
    let before = worktree.entries(&head, &raws).unwrap();

    let kept = worktree
        .recover_staging("CRASH", &before, &HashMap::new())
        .unwrap();

    // keep.txt's path is taken, so its save stays aside; gone.txt's is
    // empty, and its save goes back there.
    assert_eq!(kept.len(), 1);
    assert_eq!(kept[0].path, "keep.txt");
    assert!(!staging.join("gen-2").exists());
    assert!(!staging.join("ready-1/a.txt").exists());
    assert!(staging.join("ready-1/keep.txt").exists());
    // A save stays aside, so the area keeps the file that hides it from
    // Git: the check for an emptied area lists it anew, not from where the
    // listing above ended.
    assert!(worktree.staging("CRASH").join(".gitignore").exists());
    assert_eq!(
        repo.read("gone.txt").as_deref(),
        Some("taken out, then saved to\n")
    );
}

/// A staging area that is a link to somewhere else is not cleared: what it
/// points at is not the operation's, and nothing there is deleted. The
/// journal stays unsettled, for a later recovery to look at again.
#[cfg(unix)]
#[test]
fn recovery_never_follows_a_staging_area_that_is_a_link() {
    let repo = Repo::new("staging-link");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let mut journal = restored.clone();
    journal.op_id = new_op_id();
    journal.stage = RestoreStage::Writing { done: Vec::new() };
    assert!(worktree.write_journal(&journal).is_ok());

    let elsewhere = repo.scratch.join("elsewhere");
    fs::create_dir_all(elsewhere.join("side/gen-1")).unwrap();
    fs::write(elsewhere.join("side/gen-1/keep.txt"), "not the restore's\n").unwrap();
    let staging = worktree.staging(&journal.op_id);
    let _ = fs::remove_dir_all(&staging);
    std::os::unix::fs::symlink(&elsewhere, &staging).unwrap();

    let _ = recover(&repo.path, NOW).unwrap();

    assert!(elsewhere.join("side/gen-1/keep.txt").exists());
    assert!(
        worktree
            .journal(&journal.op_id)
            .unwrap()
            .unwrap()
            .stage
            .is_interrupted()
    );
}

/// Settling an operation after a crash rewrites `at`, the time of the
/// call that last wrote its journal, and so does marking it undone; when it
/// ran stays as it was. A turn that began between the crash and the
/// recovery began after the restore, which the app tells by `ranAt`.
#[test]
fn recovery_and_undo_keep_when_the_operation_ran() {
    let repo = Repo::new("recover-ran-at");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    assert_eq!(restored.ran_at.as_deref(), Some(NOW));
    let worktree = repo.worktree();
    let ran = "2026-10-12T00:00:00Z";
    let mut cut_short = restored.clone();
    cut_short.stage = RestoreStage::Writing { done: Vec::new() };
    ran.clone_into(&mut cut_short.at);
    cut_short.ran_at = Some(ran.to_owned());
    assert!(worktree.write_journal(&cut_short).is_ok());

    let recovered_at = "2026-10-12T06:00:00Z";
    let recovery = recover(&repo.path, recovered_at).unwrap();

    assert_eq!(recovery.settled, std::slice::from_ref(&restored.op_id));
    let settled = worktree.journal(&restored.op_id).unwrap().unwrap();
    assert_eq!(settled.stage, RestoreStage::Applied);
    assert_eq!(settled.at, recovered_at);
    assert_eq!(settled.ran_at.as_deref(), Some(ran));

    let undo = finished(repo.undo(&restored.op_id));
    let undone = worktree.journal(&restored.op_id).unwrap().unwrap();
    assert_eq!(undone.stage, RestoreStage::Undone { by: undo.op_id });
    assert_eq!(undone.at, NOW);
    assert_eq!(undone.ran_at.as_deref(), Some(ran));
}

/// Journals that are there but cannot be read are no empty list: the
/// reading says it is incomplete, so the app never reads the worktree as
/// having no operation to show or settle. A folder that is gone, or no
/// repository, has none, and its reading is whole.
#[test]
fn journals_that_cannot_be_read_are_an_incomplete_list_not_none() {
    use std::os::unix::fs::PermissionsExt;
    let repo = Repo::new("recover-unreadable");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let directory = worktree.journal_directory();
    let file = worktree.journal_path(&restored.op_id);
    let set_mode = |path: &Path, mode: u32| {
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    };

    set_mode(&directory, 0o000);
    let unreadable_directory = recover(&repo.path, NOW);
    set_mode(&directory, 0o700);
    let unreadable_directory = unreadable_directory.unwrap();
    assert!(unreadable_directory.is_incomplete);
    assert!(unreadable_directory.journals.is_empty());
    assert!(unreadable_directory.settled.is_empty());

    set_mode(&file, 0o000);
    let unreadable_file = recover(&repo.path, NOW);
    let undo = refused(repo.undo(&restored.op_id));
    set_mode(&file, 0o600);
    let unreadable_file = unreadable_file.unwrap();
    assert!(unreadable_file.is_incomplete);
    assert!(unreadable_file.journals.is_empty());
    // Not "no such restore", which the app takes as lasting.
    assert!(
        matches!(undo, Refusal::JournalUnreadable { .. }),
        "{undo:?}"
    );

    let whole = recover(&repo.path, NOW).unwrap();
    assert_eq!(whole.journals.len(), 1);
    assert!(!whole.is_incomplete);
    let not_a_repository = repo.scratch.join("elsewhere");
    fs::create_dir_all(&not_a_repository).unwrap();
    for root in [repo.scratch.join("gone"), not_a_repository] {
        assert_eq!(recover(&root, NOW).unwrap(), Recovery::default());
    }
}

/// A file that is no journal this build can decode is left out:
/// reading it again cannot go otherwise, and it must not hide the others.
#[test]
fn a_journal_that_cannot_be_decoded_is_left_out() {
    let repo = Repo::new("recover-undecodable");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    fs::write(worktree.journal_path(&new_op_id()), b"{").unwrap();

    let journals = recover(&repo.path, NOW).unwrap().journals;

    assert_eq!(
        journals
            .iter()
            .map(|journal| journal.op_id.as_str())
            .collect::<Vec<_>>(),
        [restored.op_id.as_str()]
    );
}

/// One journal that stays unreadable keeps no other from being settled or
/// dropped at launch, entered as the app enters it: the readable one a
/// crash cut short is settled and said once, the readable one past its
/// lifetime goes with its ref, and the unreadable one stays as it is on
/// disk, refs and all, with the reading said to be incomplete.
#[test]
fn recover_settles_and_prunes_the_readable_journals_beside_an_unreadable_one() {
    use std::os::unix::fs::PermissionsExt;
    let repo = Repo::new("recover-unreadable-sibling");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    // Readable, cut short by a crash: its paths hold what it wrote.
    let mut cut_short = restored.clone();
    cut_short.stage = RestoreStage::Writing { done: Vec::new() };
    assert!(worktree.write_journal(&cut_short).is_ok());
    // Readable, finished, and past its lifetime.
    let mut expired = restored.clone();
    expired.op_id = new_op_id();
    "2026-01-01T00:00:00Z".clone_into(&mut expired.at);
    expired.stage = RestoreStage::Aborted {
        reason: StageReason::ExternalChangeDetected,
    };
    assert!(worktree.write_journal(&expired).is_ok());
    repo.git(&[
        "update-ref",
        &restore_undo_ref(&expired.op_id),
        &expired.before_tree,
    ]);
    // Unreadable: a restore a crash cut short too, its trees pinned. Were
    // it read, it would be settled and written again.
    let mut kept = cut_short.clone();
    kept.op_id = new_op_id();
    assert!(worktree.write_journal(&kept).is_ok());
    let unreadable = worktree.journal_path(&kept.op_id);
    let bytes = fs::read(&unreadable).unwrap();
    let pinned = held(&repo, &kept.op_id);
    assert!(!pinned.0.is_empty() && pinned.1, "{pinned:?}");
    fs::set_permissions(&unreadable, fs::Permissions::from_mode(0o000)).unwrap();

    let recovery = recover(&repo.path, NOW);
    let again = recover(&repo.path, NOW);
    fs::set_permissions(&unreadable, fs::Permissions::from_mode(0o600)).unwrap();
    let recovery = recovery.unwrap();

    assert!(recovery.is_incomplete);
    assert_eq!(recovery.settled, std::slice::from_ref(&restored.op_id));
    assert_eq!(
        recovery
            .journals
            .iter()
            .map(|journal| (journal.op_id.as_str(), &journal.stage))
            .collect::<Vec<_>>(),
        [(restored.op_id.as_str(), &RestoreStage::Applied)]
    );
    // Told once: the next reading settles nothing, and is still incomplete.
    let again = again.unwrap();
    assert!(again.is_incomplete);
    assert!(again.settled.is_empty());
    // The expired one went, with its ref.
    assert!(!worktree.journal_path(&expired.op_id).exists());
    assert!(!is_pinned(&repo, &restore_undo_ref(&expired.op_id)));
    // The unreadable one is as it was, refs and all.
    assert_eq!(fs::read(&unreadable).unwrap(), bytes);
    assert_eq!(held(&repo, &kept.op_id), pinned);

    // Readable again, it is settled in turn, and the reading is whole.
    let whole = recover(&repo.path, NOW).unwrap();
    assert!(!whole.is_incomplete);
    assert_eq!(whole.settled, std::slice::from_ref(&kept.op_id));
    assert!(
        whole
            .journals
            .iter()
            .any(|journal| journal.op_id == kept.op_id && !journal.stage.is_interrupted())
    );
}

/// Journals come oldest first by when each ran: one a later call settled
/// after a crash, whose `at` is that call's, still comes before an
/// operation that ran after it. The app's latest undoable restore is the
/// last of them.
#[test]
fn journals_are_ordered_by_when_each_ran() {
    let repo = Repo::new("recover-order");
    let turn = busy_turn(&repo);
    let later = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let mut earlier = later.clone();
    earlier.op_id = new_op_id();
    earlier.ran_at = Some("2026-10-12T00:00:00Z".to_owned());
    // Settled by a call after `later` ran.
    "2026-10-13T00:00:01Z".clone_into(&mut earlier.at);
    assert!(worktree.write_journal(&earlier).is_ok());

    let journals = recover(&repo.path, NOW).unwrap().journals;

    assert_eq!(
        journals
            .iter()
            .map(|journal| journal.op_id.as_str())
            .collect::<Vec<_>>(),
        [earlier.op_id.as_str(), later.op_id.as_str()]
    );
}
