//! Turn snapshots and the worktree intercept against a real scratch
//! repository. Unix only: the hook runtime itself only runs there.
#![cfg(unix)]

use limpid_agent_hook::{
    GitSnapshots, HookEnv, HookOutcome, HookRuntime, InterceptResult, NoSnapshots, SnapshotRunner,
    run_worktree_hook,
};
use limpid_agent_model::WorktreeIntent;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const PANE: &str = "6F1D6A1E-0E34-4A1A-9A8E-2F2B6C1D7F10";

struct Repo {
    root: PathBuf,
    path: PathBuf,
}

impl Repo {
    fn new(name: &str) -> Self {
        Self::at(name, "repo")
    }

    /// A repository at `root/<directory>`, so a test can pick a directory
    /// name with characters a file URL has to escape.
    fn at(name: &str, directory: &str) -> Self {
        let root =
            std::env::temp_dir().join(format!("limpid-hook-git-{name}-{}", uuid::Uuid::new_v4()));
        let path = root.join(directory);
        fs::create_dir_all(&path).expect("repo dir");
        git(&path, &["init", "-q", "-b", "main"]);
        fs::write(path.join("README.md"), "fixture\n").expect("readme");
        git(&path, &["add", "README.md"]);
        git(
            &path,
            &[
                "-c",
                "user.name=fixture",
                "-c",
                "user.email=fixture@example.com",
                "commit",
                "-q",
                "-m",
                "base",
            ],
        );
        Self { root, path }
    }

    fn git_dir(&self) -> PathBuf {
        self.path.join(".git")
    }
}

impl Drop for Repo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// Runs git without the developer's own configuration, so a global
/// `commit.gpgsign` or `core.hooksPath` cannot stall the fixture setup.
fn git(cwd: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .output()
        .expect("git runs");
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

#[test]
fn capture_writes_a_private_index_and_ref_without_touching_the_real_index() {
    let repo = Repo::new("capture");
    fs::write(repo.path.join("untracked.txt"), "new\n").expect("untracked");
    let snapshot = GitSnapshots.capture(&repo.path, PANE).expect("snapshot");
    assert_eq!(snapshot.tree.len(), 40);
    assert_eq!(
        Path::new(&snapshot.root).canonicalize().ok(),
        repo.path.canonicalize().ok()
    );
    let key = PANE.to_ascii_lowercase();
    assert_eq!(
        git(
            &repo.path,
            &["rev-parse", &format!("refs/limpid/turn/{key}")]
        )
        .as_deref(),
        Some(snapshot.tree.as_str())
    );
    assert!(
        repo.git_dir()
            .join("limpid")
            .join(format!("turn-{key}.index"))
            .exists()
    );
    // The untracked file is in the snapshot tree but still untracked for the user.
    assert!(
        git(&repo.path, &["ls-tree", "--name-only", &snapshot.tree])
            .expect("tree")
            .contains("untracked.txt")
    );
    assert_eq!(
        git(&repo.path, &["status", "--porcelain"]).as_deref(),
        Some("?? untracked.txt")
    );

    fs::write(
        repo.git_dir()
            .join("limpid")
            .join(format!("turn-{key}.read.index")),
        b"",
    )
    .expect("read index");
    GitSnapshots.remove(&repo.path, PANE).expect("remove");
    assert_eq!(
        git(
            &repo.path,
            &[
                "rev-parse",
                "--verify",
                "-q",
                &format!("refs/limpid/turn/{key}")
            ]
        ),
        None
    );
    assert!(
        !repo
            .git_dir()
            .join("limpid")
            .join(format!("turn-{key}.index"))
            .exists()
    );
    assert!(
        !repo
            .git_dir()
            .join("limpid")
            .join(format!("turn-{key}.read.index"))
            .exists()
    );
}

#[test]
fn capture_outside_a_repository_yields_nothing() {
    let outside = std::env::temp_dir().join(format!("limpid-hook-norepo-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&outside).expect("dir");
    assert_eq!(GitSnapshots.capture(&outside, PANE), None);
    assert_eq!(GitSnapshots.remove(&outside, PANE), Ok(()));
    let _ = fs::remove_dir_all(&outside);
}

/// The state file as the app writes it: projects sit inside the sidebar's
/// containers next to groups.
fn state_json(repo: &Repo, extra: &str) -> PathBuf {
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    fs::write(
        repo.root.join("support").join("state.json"),
        format!(
            r#"{{"version":5,"containers":[{{"kind":"group","group":{{"name":"g"}}}},{{"kind":"project","project":{{"name":"repo","rootURL":"file://{}/","worktreePlacement":{{"siblingPrefixed":{{}}}},"bootstrap":["mkdir sub",{{"cmd":"touch nested.txt","cwd":"sub"}},{{"cmd":"touch escaped.txt","cwd":".."}}]{extra}}}}}]}}"#,
            repo.path.display()
        ),
    )
    .expect("state.json");
    states
}

#[test]
fn intercept_also_reads_the_pre_container_projects_array() {
    let repo = Repo::new("legacy-state");
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    fs::write(
        repo.root.join("support").join("state.json"),
        format!(
            r#"{{"projects":[{{"rootURL":"file://{}/","worktreePlacement":{{"insideHidden":{{}}}}}}]}}"#,
            repo.path.display()
        ),
    )
    .expect("state.json");
    let intent = WorktreeIntent::parse(
        "git worktree add -b demo ../demo",
        Some(repo.path.to_str().expect("path")),
    )
    .expect("intent");
    let result = limpid_agent_hook::run_worktree_intercept(&intent, "claude", &states);
    let expected = repo.path.join(".worktrees").join("demo");
    assert!(matches!(result, InterceptResult::Created { path, .. } if path == expected));
    assert!(expected.join("README.md").exists());
}

#[test]
fn intercept_creates_the_worktree_where_the_project_says_and_notifies() {
    let repo = Repo::new("intercept");
    let states = state_json(&repo, "");
    let intent = WorktreeIntent::parse(
        "git worktree add -b feature/demo ../demo",
        Some(repo.path.to_str().expect("path")),
    )
    .expect("intent");
    let result = limpid_agent_hook::run_worktree_intercept(&intent, "claude", &states);
    let expected = repo.root.join("repo-demo");
    assert_eq!(
        result,
        InterceptResult::Created {
            repo_root: repo.path.clone(),
            path: expected.clone(),
            branch: "feature/demo".into(),
            message: format!("Limpid created worktree at {}.", expected.display()),
        }
    );
    assert!(expected.join("README.md").exists());
    assert_eq!(
        git(&expected, &["branch", "--show-current"]).as_deref(),
        Some("feature/demo")
    );
    assert!(
        expected.join("sub").join("nested.txt").exists(),
        "string steps run in the worktree and a relative cwd resolves inside it"
    );
    // `..` of the worktree is a directory that exists, so this proves the
    // guard and not a failed `chdir`.
    assert!(
        !repo.root.join("escaped.txt").exists(),
        "an escaping cwd is skipped"
    );
    let events: Vec<PathBuf> = fs::read_dir(states.join("worktree-events"))
        .expect("events")
        .flatten()
        .map(|entry| entry.path())
        .collect();
    assert_eq!(events.len(), 1);
    let event: serde_json::Value =
        serde_json::from_slice(&fs::read(&events[0]).expect("event")).expect("json");
    assert_eq!(event["event"], "WorktreeCreate");
    assert_eq!(event["branch"], "feature/demo");
    assert_eq!(event["worktreePath"], expected.to_string_lossy().as_ref());
}

#[test]
fn intercept_decodes_file_urls_and_honors_a_custom_placement() {
    let repo = Repo::at("custom", "My 開発");
    let states = repo.root.join("support").join("agent-states");
    fs::create_dir_all(&states).expect("states");
    let parent = repo.root.join("wt dir");
    // The URLs are written as Swift's `URL` encodes them.
    fs::write(
        repo.root.join("support").join("state.json"),
        format!(
            r#"{{"version":5,"containers":[{{"kind":"project","project":{{"name":"repo","rootURL":"file://{root}/My%20%E9%96%8B%E7%99%BA/","worktreePlacement":{{"custom":{{"_0":"file://{root}/wt%20dir/"}}}}}}}}]}}"#,
            root = repo.root.display()
        ),
    )
    .expect("state.json");
    let intent = WorktreeIntent::parse(
        "git worktree add -b demo ../demo",
        Some(repo.path.to_str().expect("path")),
    )
    .expect("intent");
    let result = limpid_agent_hook::run_worktree_intercept(&intent, "claude", &states);
    let expected = parent.join("demo");
    assert!(
        matches!(&result, InterceptResult::Created { path, .. } if *path == expected),
        "{result:?}"
    );
    assert!(expected.join("README.md").exists());
}

#[test]
fn intercept_passes_through_when_routing_is_off_or_the_project_is_unknown() {
    let repo = Repo::new("passthrough");
    let intent = WorktreeIntent::parse(
        "git worktree add -b demo ../demo",
        Some(repo.path.to_str().expect("path")),
    )
    .expect("intent");
    let states = state_json(&repo, r#","routeClaudeWorktrees":false"#);
    assert_eq!(
        limpid_agent_hook::run_worktree_intercept(&intent, "claude", &states),
        InterceptResult::Passthrough
    );
    assert!(matches!(
        limpid_agent_hook::run_worktree_intercept(&intent, "codex", &states),
        InterceptResult::Created { .. }
    ));
    let elsewhere = repo.root.join("elsewhere");
    fs::create_dir_all(&elsewhere).expect("dir");
    let outside = WorktreeIntent::parse(
        "git worktree add -b other ../x",
        Some(elsewhere.to_str().expect("path")),
    )
    .expect("intent");
    assert_eq!(
        limpid_agent_hook::run_worktree_intercept(&outside, "claude", &states),
        InterceptResult::Passthrough
    );
}

#[test]
fn worktree_hook_exits_two_with_the_message_on_success() {
    let repo = Repo::new("hook");
    let states = state_json(&repo, "");
    let env = HookEnv::from_pairs([
        ("LIMPID_PANE_ID", PANE),
        ("LIMPID_AGENT_STATES_DIR", states.to_str().expect("path")),
        (
            "LIMPID_SESSIONS_DIR",
            repo.root.join("support/sessions").to_str().expect("path"),
        ),
    ]);
    let runtime = HookRuntime::new(&env, &NoSnapshots);
    let payload = format!(
        r#"{{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"{}","tool_input":{{"command":"git worktree add -b demo ../demo"}}}}"#,
        repo.path.display()
    );
    let outcome = run_worktree_hook("claude", payload.as_bytes(), &runtime);
    assert_eq!(outcome.exit_code(), 2);
    assert!(
        matches!(outcome, HookOutcome::Intercepted { message, .. } if message.contains("repo-demo"))
    );
    let other =
        r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#;
    assert_eq!(
        run_worktree_hook("claude", other.as_bytes(), &runtime),
        HookOutcome::Applied
    );
}
