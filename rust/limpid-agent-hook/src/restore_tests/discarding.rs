//! Discarding hunks.

use super::*;

/// Ten lines, so a change near each end makes two hunks.
const LINES: &str = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";

/// A turn that changes the first and the last line of `f.txt`, and adds
/// `added.txt`. Returns the turn and the trees the review diffs.
fn two_hunk_turn(repo: &Repo) -> (String, String, String) {
    repo.write("f.txt", LINES);
    repo.git(&["add", "f.txt"]);
    repo.commit("lines");
    let turn = repo.turn(|repo| {
        repo.write(
            "f.txt",
            &LINES.replace("1\n2", "one\n2").replace("10\n", "ten\n"),
        );
        repo.write("added.txt", "x\ny\n");
    });
    let record = find_turn(&repo.request(&turn).state_directories, &turn).unwrap();
    let tree = |status: &SnapshotStatus| match status {
        SnapshotStatus::Captured { tree, .. } => tree.clone(),
        other => panic!("not captured: {other:?}"),
    };
    let (from, to) = (tree(&record.begin), tree(&record.end));
    (turn, from, to)
}

fn headers(repo: &Repo, from: &str, to: &str, path: &str) -> Vec<String> {
    let diff = repo.worktree().range_patch(from, to, path).unwrap();
    crate::hunks::parse(&diff)
        .unwrap()
        .into_iter()
        .map(|hunk| hunk.header)
        .collect()
}

fn discard(
    repo: &Repo,
    turn: &str,
    from: &str,
    to: &str,
    files: Vec<DiscardFile>,
) -> DiscardOutcome {
    discard_hunks(
        &DiscardRequest {
            root: repo.path.clone(),
            from_tree: from.to_owned(),
            to_tree: to.to_owned(),
            turn_id: turn.to_owned(),
            turn_number: Some(1),
            pane_id: PANE.to_owned(),
            files,
            state_directories: repo.request(turn).state_directories,
        },
        NOW,
    )
}

fn discarded(outcome: DiscardOutcome) -> (Option<RestoreJournal>, Vec<HunkOutcome>) {
    match outcome {
        DiscardOutcome::Finished { journal, hunks } => (
            journal.map(|journal| *journal),
            hunks.into_iter().map(|hunk| hunk.result).collect(),
        ),
        DiscardOutcome::Refused { refusal } => panic!("refused: {refusal:?}"),
    }
}

/// Line endings set for a file after its hunk was discarded: its undo
/// would not give it its bytes back, and is refused.
#[test]
fn a_discards_undo_is_refused_once_git_converts_its_file() {
    let repo = Repo::new("discard-converted");
    let (turn, from, to) = two_hunk_turn(&repo);
    let hunks = headers(&repo, &from, &to, "f.txt");
    let (journal, results) = discarded(discard(
        &repo,
        &turn,
        &from,
        &to,
        vec![DiscardFile {
            path: "f.txt".to_owned(),
            hunks: hunks[..1].to_vec(),
        }],
    ));
    assert_eq!(results, [HunkOutcome::Discarded]);
    let attributes = repo.path.join(".git/info/attributes");
    fs::create_dir_all(attributes.parent().unwrap()).unwrap();
    fs::write(&attributes, "f.txt text eol=crlf\n").unwrap();

    assert_eq!(
        refused(repo.undo(&journal.unwrap().op_id)),
        Refusal::Converted {
            paths: vec!["f.txt".to_owned()]
        }
    );
}

/// Two hunks of one file; one whose lines were edited since is reported
/// and left, the other taken back, and the undo puts the file back as it
/// was before the discard.
#[test]
fn discard_hunks_partial_failure_reports_each() {
    let repo = Repo::new("discard");
    let (turn, from, to) = two_hunk_turn(&repo);
    let hunks = headers(&repo, &from, &to, "f.txt");
    assert_eq!(hunks.len(), 2);
    let edited = LINES.replace("1\n2", "one\n2").replace("10\n", "TEN\n");
    repo.write("f.txt", &edited);

    let (journal, results) = discarded(discard(
        &repo,
        &turn,
        &from,
        &to,
        vec![DiscardFile {
            path: "f.txt".to_owned(),
            hunks: hunks.clone(),
        }],
    ));

    assert_eq!(results, [HunkOutcome::Discarded, HunkOutcome::NotFound]);
    assert_eq!(
        repo.read("f.txt").as_deref(),
        Some(LINES.replace("10\n", "TEN\n").as_str())
    );
    let journal = journal.unwrap();
    assert_eq!(journal.operation, RestoreOperation::Discard);
    assert_eq!(journal.stage, RestoreStage::Applied);
    assert_eq!(
        repo.read("added.txt").as_deref(),
        Some("x\ny\n"),
        "another file is not touched"
    );

    let undo = finished(repo.undo(&journal.op_id));
    assert_eq!(undo.stage, RestoreStage::Applied);
    assert_eq!(undo.operation, RestoreOperation::Discard);
    assert_eq!(repo.read("f.txt").as_deref(), Some(edited.as_str()));
}

/// A file the range added goes when its only hunk is taken back; a hunk
/// the range's diff does not have writes nothing.
#[test]
fn discarding_an_added_file_deletes_it_and_an_unknown_hunk_writes_nothing() {
    let repo = Repo::new("discard-added");
    let (turn, from, to) = two_hunk_turn(&repo);
    let added = headers(&repo, &from, &to, "added.txt");

    let (journal, results) = discarded(discard(
        &repo,
        &turn,
        &from,
        &to,
        vec![DiscardFile {
            path: "added.txt".to_owned(),
            hunks: added,
        }],
    ));
    assert_eq!(results, [HunkOutcome::Discarded]);
    assert!(journal.is_some());
    assert_eq!(repo.read("added.txt"), None);

    let (journal, results) = discarded(discard(
        &repo,
        &turn,
        &from,
        &to,
        vec![DiscardFile {
            path: "f.txt".to_owned(),
            hunks: vec!["@@ -40,1 +40,1 @@".to_owned()],
        }],
    ));
    assert_eq!(results, [HunkOutcome::NotFound]);
    assert!(journal.is_none(), "nothing to write, nothing journaled");
}

#[test]
fn a_discard_is_refused_while_an_agent_of_the_worktree_runs() {
    let repo = Repo::new("discard-busy");
    let (turn, from, to) = two_hunk_turn(&repo);
    let hunks = headers(&repo, &from, &to, "f.txt");
    // A prompt: the run is at work again.
    repo.hook(
        format!(
            r#"{{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"more","cwd":"{}"}}"#,
            repo.path.display()
        )
        .as_bytes(),
    );

    let outcome = discard(
        &repo,
        &turn,
        &from,
        &to,
        vec![DiscardFile {
            path: "f.txt".to_owned(),
            hunks,
        }],
    );

    assert!(matches!(
        outcome,
        DiscardOutcome::Refused {
            refusal: Refusal::AgentActive { .. }
        }
    ));
}

/// A discard never undone goes after the journals' lifetime, refs and
/// all: no window offers its undo once the review that made it closes.
#[test]
fn an_old_discard_is_pruned_with_its_refs() {
    let repo = Repo::new("discard-prune");
    let (turn, from, to) = two_hunk_turn(&repo);
    let added = headers(&repo, &from, &to, "added.txt");
    let (journal, _) = discarded(discard(
        &repo,
        &turn,
        &from,
        &to,
        vec![DiscardFile {
            path: "added.txt".to_owned(),
            hunks: added,
        }],
    ));
    let journal = journal.unwrap();
    let restore = finished(repo.restore(&turn));

    let recovery = recover(&repo.path, "2027-01-01T00:00:00Z").unwrap();

    let kept: Vec<&str> = recovery
        .journals
        .iter()
        .map(|kept| kept.op_id.as_str())
        .collect();
    assert_eq!(
        kept,
        [restore.op_id.as_str()],
        "a restore still to be undone stays"
    );
    assert_eq!(held(&repo, &journal.op_id), (Vec::new(), false));
    assert_eq!(held(&repo, &restore.op_id).0.len(), 3);
}

/// A file git converts on checkout (line endings here) cannot be written
/// back byte for byte, so its hunks are not discarded.
#[test]
fn a_file_git_converts_is_not_discarded() {
    let repo = Repo::new("discard-eol");
    let (turn, from, to) = two_hunk_turn(&repo);
    let hunks = headers(&repo, &from, &to, "f.txt");
    repo.write(".gitattributes", "f.txt text eol=crlf\n");
    let before = repo.read("f.txt");

    let (journal, results) = discarded(discard(
        &repo,
        &turn,
        &from,
        &to,
        vec![DiscardFile {
            path: "f.txt".to_owned(),
            hunks,
        }],
    ));

    assert_eq!(results, [HunkOutcome::Converted, HunkOutcome::Converted]);
    assert!(journal.is_none());
    assert_eq!(repo.read("f.txt"), before);
}

/// A link where the file was is not the file the hunk is in.
#[cfg(unix)]
#[test]
fn a_link_where_the_file_was_is_not_discarded() {
    let repo = Repo::new("discard-link");
    let (turn, from, to) = two_hunk_turn(&repo);
    let hunks = headers(&repo, &from, &to, "f.txt");
    let content = repo.read("f.txt").unwrap();
    repo.write("target.txt", &content);
    fs::remove_file(repo.path.join("f.txt")).unwrap();
    std::os::unix::fs::symlink("target.txt", repo.path.join("f.txt")).unwrap();

    let (_, results) = discarded(discard(
        &repo,
        &turn,
        &from,
        &to,
        vec![DiscardFile {
            path: "f.txt".to_owned(),
            hunks,
        }],
    ));

    assert_eq!(
        results,
        [HunkOutcome::Unsupported, HunkOutcome::Unsupported]
    );
    assert_eq!(repo.read("target.txt").as_deref(), Some(content.as_str()));
}
