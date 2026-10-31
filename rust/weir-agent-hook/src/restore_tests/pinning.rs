//! The refs that pin each tree a journal names, and when they go.

use super::*;

/// Both trees an undo reads are pinned while it may run, and let go once
/// it has.
#[test]
fn the_trees_are_pinned_until_the_restore_is_undone() {
    let repo = Repo::new("pinned");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    assert!(is_pinned(&repo, &restore_undo_ref(&restored.op_id)));
    assert!(is_pinned(&repo, &restore_target_ref(&restored.op_id)));
    assert!(is_pinned(&repo, &restore_expected_ref(&restored.op_id)));
    assert!(repo.worktree().refs_file(&restored.op_id).exists());

    let undo = finished(repo.undo(&restored.op_id));

    for op in [&restored.op_id, &undo.op_id] {
        assert_eq!(held(&repo, op), (Vec::new(), false), "{op}");
    }
}

/// Each tree a partly applied restore names is pinned while its record may
/// be undone, and every ref goes with the record once it is.
#[test]
fn every_tree_a_journal_names_is_pinned_until_the_record_lets_go() {
    let repo = Repo::new("pinned-all");
    let turn = busy_turn(&repo);
    let journal = restore_meeting(&repo, &turn, |repo| {
        repo.write("a.txt", "editor\n");
        place_waiting_marker(repo);
    });
    assert!(matches!(
        journal.stage,
        RestoreStage::PartiallyApplied { .. }
    ));
    for (name, tree) in journal.pinned_trees() {
        assert_eq!(repo.git(&["rev-parse", &name]), tree, "{name}");
    }
    assert_eq!(held(&repo, &journal.op_id).0.len(), 4);
    fs::remove_dir_all(repo.worktree().git_dir.join("weir/worktree.lock.waiting")).unwrap();

    let undo = finished(repo.undo(&journal.op_id));

    assert_eq!(undo.stage, RestoreStage::Applied);
    for op in [&journal.op_id, &undo.op_id] {
        assert_eq!(held(&repo, op), (Vec::new(), false), "{op}");
    }
}

/// A restore past its lifetime goes, refs and all: the journal first, then
/// its refs, so a crash between the two leaves refs for the sweep and never
/// a journal with its trees let go.
#[test]
fn the_refs_go_with_a_pruned_record() {
    let repo = Repo::new("pruned-refs");
    let turn = busy_turn(&repo);
    repo.write("other.txt", "outside\n");
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let mut aborted = restored.clone();
    aborted.op_id = new_op_id();
    aborted.at = "2026-01-01T00:00:00Z".to_owned();
    assert!(worktree.pin_trees(&aborted).is_ok());
    aborted.stage = RestoreStage::Aborted {
        reason: StageReason::ExternalChangeDetected,
    };
    assert!(worktree.write_journal(&aborted).is_ok());
    assert_eq!(held(&repo, &aborted.op_id).0.len(), 3);

    let journals = recover(&repo.path, NOW).unwrap().journals;

    assert!(journals.iter().all(|kept| kept.op_id != aborted.op_id));
    assert_eq!(held(&repo, &aborted.op_id), (Vec::new(), false));
    assert_eq!(held(&repo, &restored.op_id).0.len(), 3);
}

/// What a crash leaves between a ref and its journal is swept by the next
/// recovery: refs with no journal (cut short before its journal, or after
/// dropping it) and refs of a journal nothing takes back. A ref no file of
/// this worktree names may be another worktree's, and stays.
#[test]
fn refs_a_crash_left_behind_are_swept() {
    let repo = Repo::new("swept-refs");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let copy = || {
        let mut copy = restored.clone();
        copy.op_id = new_op_id();
        copy
    };
    // Pinned, and the journal never written.
    let unwritten = copy();
    assert!(worktree.pin_trees(&unwritten).is_ok());
    // Pinned and written, and the journal dropped.
    let dropped = copy();
    assert!(worktree.write_journal(&dropped).is_ok());
    fs::remove_file(worktree.journal_path(&dropped.op_id)).unwrap();
    // Finished, and its refs still there.
    let mut undone = copy();
    assert!(worktree.pin_trees(&undone).is_ok());
    undone.stage = RestoreStage::Undone { by: new_op_id() };
    assert!(worktree.write_journal(&undone).is_ok());
    // Another worktree's: no file here names it.
    let elsewhere = copy();
    repo.git(&[
        "update-ref",
        &restore_undo_ref(&elsewhere.op_id),
        &elsewhere.before_tree,
    ]);
    for op in [&unwritten.op_id, &dropped.op_id, &undone.op_id] {
        assert_eq!(held(&repo, op).0.len(), 3, "{op}");
    }

    let _ = recover(&repo.path, NOW).unwrap();

    for op in [&unwritten.op_id, &dropped.op_id, &undone.op_id] {
        assert_eq!(held(&repo, op), (Vec::new(), false), "{op}");
    }
    assert!(is_pinned(&repo, &restore_undo_ref(&elsewhere.op_id)));
    assert_eq!(held(&repo, &restored.op_id).0.len(), 3);
}

/// A journal a development build wrote before the files in
/// `REFS_DIRECTORY` has none, and is not migrated: it keeps the two refs
/// that build made, and they still go by name with the journal, when it is
/// undone and when it is pruned.
#[test]
fn a_journal_without_a_file_lets_its_refs_go_by_name() {
    let repo = Repo::new("no-file");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    // As that build left it: the refs of what was there and of the target.
    repo.git(&["update-ref", "-d", &restore_expected_ref(&restored.op_id)]);
    fs::remove_file(worktree.refs_file(&restored.op_id)).unwrap();
    let mut old = restored.clone();
    old.op_id = new_op_id();
    old.at = "2026-01-01T00:00:00Z".to_owned();
    old.stage = RestoreStage::Aborted {
        reason: StageReason::ExternalChangeDetected,
    };
    assert!(worktree.store(&old).is_ok());
    repo.git(&[
        "update-ref",
        &restore_undo_ref(&old.op_id),
        &old.before_tree,
    ]);
    repo.git(&[
        "update-ref",
        &restore_target_ref(&old.op_id),
        &old.target_tree,
    ]);
    for op in [&restored.op_id, &old.op_id] {
        assert_eq!(held(&repo, op).0.len(), 2, "{op}");
    }

    let undo = finished(repo.undo(&restored.op_id));
    let journals = recover(&repo.path, NOW).unwrap().journals;

    assert_eq!(undo.stage, RestoreStage::Applied);
    assert!(journals.iter().all(|kept| kept.op_id != old.op_id));
    for op in [&restored.op_id, &old.op_id, &undo.op_id] {
        assert_eq!(held(&repo, op), (Vec::new(), false), "{op}");
    }
}

/// A file in `REFS_DIRECTORY` with refs and no journal is a crashed
/// operation or one about to write its journal, and only the lock tells
/// them apart: while another holds it, recovery leaves the refs, and once
/// it is free, drops them.
#[test]
fn refs_with_no_journal_stay_while_another_holds_the_lock() {
    let repo = Repo::new("sweep-locked");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let mut planning = restored.clone();
    planning.op_id = new_op_id();
    planning.stage = RestoreStage::Planned;
    assert!(worktree.pin_trees(&planning).is_ok());
    let lock = worktree.lock().unwrap();

    let _ = recover(&repo.path, NOW).unwrap();

    let (names, is_noted) = held(&repo, &planning.op_id);
    assert_eq!(names.len(), 3);
    assert!(is_noted);
    drop(lock);
    let _ = recover(&repo.path, NOW).unwrap();
    assert_eq!(held(&repo, &planning.op_id), (Vec::new(), false));
}

/// A damaged journal makes no `update-ref` line: an empty tree would read
/// as "delete", and a line break would add a command of its own.
#[test]
fn a_damaged_journal_pins_nothing() {
    let repo = Repo::new("damaged");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let main = repo.git(&["rev-parse", "refs/heads/main"]);
    for tree in [
        String::new(),
        format!("{}\ndelete refs/heads/main", restored.target_tree),
    ] {
        let mut damaged = restored.clone();
        damaged.op_id = new_op_id();
        damaged.expected_after_tree = tree;

        assert!(matches!(
            worktree.pin_trees(&damaged),
            Err(StoreError::Unpinnable)
        ));
        assert!(worktree.write_journal(&damaged).is_err());

        assert_eq!(held(&repo, &damaged.op_id), (Vec::new(), false));
        assert!(worktree.journal(&damaged.op_id).unwrap().is_none());
    }
    assert_eq!(repo.git(&["rev-parse", "refs/heads/main"]), main);
}

/// A crash after a partly applied restore pinned the tree it found and
/// before its journal said so; the paths are found restored since. The
/// journal settles as applied, and that tree's ref goes with the write.
#[test]
fn a_restore_recovered_as_applied_drops_the_tree_it_no_longer_names() {
    let repo = Repo::new("stale-current");
    let turn = busy_turn(&repo);
    let journal = restore_meeting(&repo, &turn, |repo| {
        repo.write("a.txt", "editor\n");
        place_waiting_marker(repo);
    });
    assert!(matches!(
        journal.stage,
        RestoreStage::PartiallyApplied { .. }
    ));
    fs::remove_dir_all(repo.worktree().git_dir.join("weir/worktree.lock.waiting")).unwrap();
    let mut cut_short = journal.clone();
    cut_short.stage = RestoreStage::Verifying;
    assert!(repo.worktree().write_progress(&cut_short).is_ok());
    repo.write("a.txt", "a\n");

    let _ = recover(&repo.path, NOW).unwrap();

    assert_eq!(
        repo.worktree()
            .journal(&journal.op_id)
            .unwrap()
            .unwrap()
            .stage,
        RestoreStage::Applied
    );
    assert!(!is_pinned(&repo, &restore_current_ref(&journal.op_id)));
    assert_eq!(held(&repo, &journal.op_id).0.len(), 3);
}

/// An undo is not undone in turn, so once it settles, whole or not, its
/// refs go: nothing reads its trees again.
#[test]
fn a_settled_undo_is_final_whole_or_not() {
    let repo = Repo::new("undo-final");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let partly = RestoreStage::PartiallyApplied {
        reason: StageReason::ExternalChangeDetected,
        current_tree: restored.before_tree.clone(),
        kept: vec!["a.txt".to_owned()],
        failed: Vec::new(),
    };
    let mut undo = restored.clone();
    undo.undoes = Some(restored.op_id.clone());
    for (stage, is_settled) in [
        (RestoreStage::Applied, true),
        (partly.clone(), true),
        (
            RestoreStage::Aborted {
                reason: StageReason::AgentStarted,
            },
            true,
        ),
        (RestoreStage::Planned, false),
        (RestoreStage::Verifying, false),
        (RestoreStage::Unknown, false),
    ] {
        undo.stage = stage;
        assert_eq!(is_final(&undo), is_settled, "{:?}", undo.stage);
    }
    let mut partial = restored;
    partial.stage = partly;
    assert!(!is_final(&partial), "a partial restore may still be undone");
}

/// An operation's refs are those its file names, so a later build's refs
/// go too; a file that names none still drops every ref this build makes;
/// a name that is not the operation's restore ref is never dropped.
#[test]
fn the_refs_a_file_names_are_dropped_and_nothing_else() {
    let repo = Repo::new("named-refs");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let op = new_op_id();
    let later = format!("refs/weir/undo-later/{op}");
    for name in [restore_undo_ref(&op), later.clone()] {
        repo.git(&["update-ref", &name, &restored.before_tree]);
    }
    // A name git refuses (`..` in it) would fail the whole transaction.
    let refused_by_git = format!("refs/weir/undo-x/a..b/{op}");
    fs::write(
        worktree.refs_file(&op),
        format!(
            "owner {}\nref {later}\nref refs/heads/main\nref {refused_by_git}\n",
            worktree.owner().unwrap()
        ),
    )
    .unwrap();

    worktree.release_refs(&op);

    assert!(!is_pinned(&repo, &later));
    assert_eq!(held(&repo, &op), (Vec::new(), false));
    assert!(is_pinned(&repo, "refs/heads/main"));

    let bare = new_op_id();
    repo.git(&[
        "update-ref",
        &restore_target_ref(&bare),
        &restored.target_tree,
    ]);
    fs::write(worktree.refs_file(&bare), "").unwrap();
    worktree.release_refs(&bare);
    assert_eq!(held(&repo, &bare), (Vec::new(), false));
}

/// Refs are the repository's and journals each worktree's. A recovery in
/// one worktree leaves another's refs while that worktree is there, and
/// drops them once git removed it, and its journals with it.
#[test]
fn the_refs_of_a_removed_worktree_go() {
    let repo = Repo::new("removed-worktree");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let linked = repo.scratch.join("linked");
    let linked_path = linked.to_str().unwrap();
    repo.git(&["worktree", "add", "-q", "--detach", linked_path]);
    let other = Worktree::open(&linked).unwrap();
    let mut theirs = restored.clone();
    theirs.op_id = new_op_id();
    theirs.root = other.root.to_string_lossy().into_owned();
    assert!(other.write_journal(&theirs).is_ok());
    // As an earlier build wrote it: the absolute git directory.
    let mut earlier = theirs.clone();
    earlier.op_id = new_op_id();
    assert!(other.write_journal(&earlier).is_ok());
    fs::write(
        other.refs_file(&earlier.op_id),
        format!(
            "gitdir {}\n",
            fs::canonicalize(&other.git_dir).unwrap().display()
        ),
    )
    .unwrap();

    let _ = recover(&repo.path, NOW).unwrap();
    let _ = recover(&linked, NOW).unwrap();

    for op in [&theirs.op_id, &earlier.op_id, &restored.op_id] {
        let (names, is_noted) = held(&repo, op);
        assert_eq!(names.len(), 3, "{op}");
        assert!(is_noted, "{op}");
    }

    repo.git(&["worktree", "remove", "--force", linked_path]);
    let _ = recover(&repo.path, NOW).unwrap();

    for op in [&theirs.op_id, &earlier.op_id] {
        assert_eq!(held(&repo, op), (Vec::new(), false), "{op}");
    }
    assert_eq!(held(&repo, &restored.op_id).0.len(), 3);
}

/// The files in `REFS_DIRECTORY` name their worktree from the common git
/// directory, so a repository moved keeps every undo pinned: the next
/// recovery at the new place drops nothing, not even for a file an earlier
/// build wrote with the old absolute path, which names no worktree it can
/// place.
#[test]
fn a_moved_repository_keeps_its_refs() {
    let repo = Repo::new("moved-repo");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let mut earlier = restored.clone();
    earlier.op_id = new_op_id();
    assert!(worktree.write_journal(&earlier).is_ok());
    fs::write(
        worktree.refs_file(&earlier.op_id),
        format!(
            "gitdir {}\n",
            fs::canonicalize(&worktree.git_dir).unwrap().display()
        ),
    )
    .unwrap();
    let moved = Repo {
        scratch: repo.scratch.join("none"),
        path: repo.scratch.join("moved"),
        states: repo.states.clone(),
    };
    fs::rename(&repo.path, &moved.path).unwrap();

    let _ = recover(&moved.path, NOW).unwrap();

    for op in [&restored.op_id, &earlier.op_id] {
        let (names, is_noted) = held(&moved, op);
        assert_eq!(names.len(), 3, "{op}");
        assert!(is_noted, "{op}");
    }
}

/// `git worktree move` and `git worktree lock` keep the worktree's git
/// directory where it was, so its refs stay, whichever worktree recovers.
#[test]
fn a_moved_or_locked_worktree_keeps_its_refs() {
    let repo = Repo::new("moved-linked");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let linked = repo.scratch.join("linked");
    let moved = repo.scratch.join("moved-linked");
    repo.git(&[
        "worktree",
        "add",
        "-q",
        "--detach",
        linked.to_str().unwrap(),
    ]);
    let other = Worktree::open(&linked).unwrap();
    let mut theirs = restored.clone();
    theirs.op_id = new_op_id();
    theirs.root = other.root.to_string_lossy().into_owned();
    assert!(other.write_journal(&theirs).is_ok());
    repo.git(&[
        "worktree",
        "move",
        linked.to_str().unwrap(),
        moved.to_str().unwrap(),
    ]);
    repo.git(&["worktree", "lock", moved.to_str().unwrap()]);

    let _ = recover(&repo.path, NOW).unwrap();
    let _ = recover(&moved, NOW).unwrap();

    for op in [&theirs.op_id, &restored.op_id] {
        let (names, is_noted) = held(&repo, op);
        assert_eq!(names.len(), 3, "{op}");
        assert!(is_noted, "{op}");
    }
}

/// A file that names its worktree in a way that is not `.` or
/// `worktrees/<name>` (damaged, or none at all) is one we cannot place, and
/// its refs stay, though nothing is at the path it names.
#[test]
fn a_file_naming_no_worktree_keeps_its_refs() {
    let repo = Repo::new("unplaced");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let mut ops = Vec::new();
    for owner in [
        "owner elsewhere/gone\n",
        "owner worktrees/../../gone\n",
        "owner \n",
        "",
    ] {
        let op = new_op_id();
        repo.git(&["update-ref", &restore_undo_ref(&op), &restored.before_tree]);
        fs::write(worktree.refs_file(&op), owner).unwrap();
        ops.push(op);
    }

    let _ = recover(&repo.path, NOW).unwrap();

    for op in &ops {
        assert_eq!(held(&repo, op), (vec![restore_undo_ref(op)], true), "{op}");
    }
}

/// A restore's pins are `update`s alone, so another `git` holding
/// `packed-refs.lock` (a `pack-refs`, a `gc`) does not refuse it: only a
/// `delete` waits on that lock.
#[test]
fn a_restore_runs_while_packed_refs_is_locked() {
    let repo = Repo::new("packed-lock");
    let turn = busy_turn(&repo);
    let packed_lock = repo.worktree().git_dir.join("packed-refs.lock");
    fs::write(&packed_lock, "").unwrap();

    let journal = finished(repo.restore(&turn));

    fs::remove_file(&packed_lock).unwrap();
    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(held(&repo, &journal.op_id).0.len(), 3);
}

/// When git refuses a ref the file names (here, one another git holds
/// locked), the refs this build makes go on their own, and the file stays
/// for the rest.
#[test]
fn a_release_git_refuses_still_drops_this_builds_refs() {
    let repo = Repo::new("release-refused");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    let op = new_op_id();
    let later = format!("refs/weir/undo-later/{op}");
    for name in [restore_undo_ref(&op), later.clone()] {
        repo.git(&["update-ref", &name, &restored.before_tree]);
    }
    fs::write(worktree.refs_file(&op), format!("owner .\nref {later}\n")).unwrap();
    let locked = worktree
        .common_dir
        .join(format!("refs/weir/undo-later/{op}.lock"));
    fs::write(&locked, "").unwrap();

    worktree.release_refs(&op);

    assert!(!is_pinned(&repo, &restore_undo_ref(&op)));
    assert!(is_pinned(&repo, &later));
    assert!(worktree.refs_file(&op).exists());
    fs::remove_file(&locked).unwrap();
    worktree.release_refs(&op);
    assert!(!is_pinned(&repo, &later));
    assert!(!worktree.refs_file(&op).exists());
}

/// A damaged file can name a removed worktree for a live one: by a second
/// owner line, or by its one owner line rewritten. Neither drops refs a
/// journal still names, whichever worktree recovers.
#[test]
fn a_damaged_owner_never_reads_a_live_worktree_as_removed() {
    let repo = Repo::new("damaged-owner");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let linked = repo.scratch.join("linked");
    repo.git(&[
        "worktree",
        "add",
        "-q",
        "--detach",
        linked.to_str().unwrap(),
    ]);
    let other = Worktree::open(&linked).unwrap();
    let journal_in = |worktree: &Worktree| {
        let mut journal = restored.clone();
        journal.op_id = new_op_id();
        assert!(worktree.write_journal(&journal).is_ok());
        journal.op_id
    };
    let gone = "owner worktrees/missing\n";
    // A second owner line after the true one.
    let doubled = journal_in(&other);
    let file = other.refs_file(&doubled);
    let contents = fs::read_to_string(&file).unwrap();
    fs::write(&file, format!("{contents}{gone}")).unwrap();
    // The one owner line rewritten, of a linked worktree's journal and of
    // the main worktree's.
    let mut rewritten = Vec::new();
    for worktree in [&other, &repo.worktree()] {
        let op = journal_in(worktree);
        let file = worktree.refs_file(&op);
        let contents = fs::read_to_string(&file).unwrap();
        let refs = contents
            .lines()
            .filter(|line| line.starts_with("ref "))
            .map(|line| format!("{line}\n"))
            .collect::<Vec<_>>()
            .concat();
        fs::write(&file, format!("{gone}{refs}")).unwrap();
        rewritten.push(op);
    }

    let _ = recover(&repo.path, NOW).unwrap();
    let _ = recover(&linked, NOW).unwrap();

    for op in std::iter::once(&doubled).chain(&rewritten) {
        let (names, is_noted) = held(&repo, op);
        assert_eq!(names.len(), 3, "{op}");
        assert!(is_noted, "{op}");
    }
    let parsed = Noted::parse(&doubled, &fs::read_to_string(&file).unwrap());
    assert!(parsed.owner.is_none());
    assert_eq!(parsed.names.len(), 3);
}

/// An all-zero id names no object, and `update-ref` given one deletes the
/// ref: a journal with a tree zeroed pins nothing, is not written, and a
/// ref it would have set keeps what it held.
#[test]
fn a_zeroed_tree_never_deletes_a_ref() {
    let repo = Repo::new("zeroed");
    let turn = busy_turn(&repo);
    let restored = finished(repo.restore(&turn));
    let worktree = repo.worktree();
    for zeros in [40, 64] {
        assert!(!is_object_id(&"0".repeat(zeros)), "{zeros}");
    }
    let mut zeroed = restored.clone();
    zeroed.before_tree = "0".repeat(40);

    assert!(matches!(
        worktree.pin_trees(&zeroed),
        Err(StoreError::Unpinnable)
    ));
    assert!(worktree.write_journal(&zeroed).is_err());

    assert_eq!(
        worktree
            .journal(&restored.op_id)
            .unwrap()
            .unwrap()
            .before_tree,
        restored.before_tree
    );
    assert_eq!(
        repo.git(&["rev-parse", &restore_undo_ref(&restored.op_id)]),
        restored.before_tree
    );
}

#[test]
fn only_restore_refs_and_worktree_names_are_read_from_a_file() {
    let op = new_op_id();
    for name in [
        format!("refs/weir/undo/{op}"),
        format!("refs/weir/undo-current/{op}"),
        format!("refs/weir/undo-later/{op}"),
    ] {
        assert!(is_restore_ref(&name, &op), "{name}");
    }
    for name in [
        format!("refs/weir/undo-x/a..b/{op}"),
        format!("refs/weir/undo-X/{op}"),
        format!("refs/weir/undo-/{op}"),
        format!("refs/weir/undoing/{op}"),
        format!("refs/heads/{op}"),
        format!("refs/weir/undo/{op}/more"),
        format!("refs/weir/undo/{}", new_op_id()),
    ] {
        assert!(!is_restore_ref(&name, &op), "{name}");
    }
    for name in [".", "worktrees/linked"] {
        assert!(is_worktree_name(name), "{name}");
    }
    for name in [
        "",
        "..",
        "worktrees/",
        "worktrees/..",
        "worktrees/a/b",
        "elsewhere",
    ] {
        assert!(!is_worktree_name(name), "{name}");
    }
}

/// A file listing the refs that cannot be written is the journal's failure,
/// and the refusal says so with its cause, not that git refused the refs.
#[test]
fn an_unwritable_refs_file_refuses_as_the_journal_with_its_cause() {
    let repo = Repo::new("refs-file");
    let turn = busy_turn(&repo);
    // A file where the directory of refs files goes: nothing can be made in
    // it.
    let weir = repo.path.join(".git/weir");
    fs::create_dir_all(&weir).unwrap();
    fs::write(weir.join("restore-refs"), "").unwrap();

    let refusal = refused(repo.restore(&turn));

    let Refusal::JournalUnwritable { cause } = &refusal else {
        panic!("{refusal:?}");
    };
    assert!(cause.starts_with("refs file:"), "{cause}");
    assert_eq!(repo.read("a.txt").as_deref(), Some("a\nchanged\n"));
}
