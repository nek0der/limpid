//! Intercepts the agent's `git worktree add` so the worktree lands where the
//! active project's placement rules say, then runs the project's bootstrap
//! steps and tells the agent where the worktree is.
//!
//! The rules are those of `weir-pretool-worktree-hook`: anything that is
//! not a confident match passes through untouched, and the only success is a
//! worktree created by Weir itself, reported with exit status 2 so the
//! provider cancels the original command and shows the message to the model.

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use weir_agent_model::WorktreeIntent;

/// The routing file version this build reads.
const ROUTING_SCHEMA_VERSION: u64 = 1;

/// The routing file's name in the application support folder. The application
/// writes it (`WorktreeRouting.fileName`); the two sides check the name against
/// `rust/fixtures/contract/shared-values.json`.
pub const WORKTREE_ROUTING_FILE: &str = "worktree-routing.json";

/// What the intercept decided.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InterceptResult {
    /// Let the agent's own command run.
    Passthrough,
    /// Weir created the worktree; the agent must not run its command. The
    /// caller records the creation, so one writer owns the event format.
    Created {
        repo_root: PathBuf,
        path: PathBuf,
        branch: String,
        message: String,
    },
}

/// The routing entry that owns `cwd`.
struct ProjectRules {
    root: PathBuf,
    placement: Placement,
    bootstrap: Vec<BootstrapStep>,
}

enum Placement {
    SiblingPrefixed,
    InsideHidden,
    Custom(PathBuf),
}

struct BootstrapStep {
    command: String,
    cwd: Option<String>,
}

/// Runs the intercept for `intent` on behalf of `provider_id`. `state_dir`
/// is the provider's agent-state directory; the routing file sits beside it.
#[must_use]
pub fn run(intent: &WorktreeIntent, provider_id: &str, state_dir: &Path) -> InterceptResult {
    let Some(support) = state_dir.parent() else {
        return InterceptResult::Passthrough;
    };
    let cwd = intent
        .cwd
        .clone()
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_default();
    let Some(project) = project_for(support, &cwd, provider_id) else {
        return InterceptResult::Passthrough;
    };
    let Some(worktree) = project.worktree_path(&intent.branch) else {
        return InterceptResult::Passthrough;
    };
    if let Some(parent) = worktree.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Run `git worktree add` ourselves; if it fails, the agent's original
    // command surfaces the failure, which is better than swallowing it.
    let created = Command::new("git")
        .arg("-C")
        .arg(&project.root)
        .args(["worktree", "add", "-b", &intent.branch])
        .arg(&worktree)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if !created {
        return InterceptResult::Passthrough;
    }
    run_bootstrap(&project.bootstrap, &worktree);
    InterceptResult::Created {
        repo_root: project.root,
        message: format!("Weir created worktree at {}.", worktree.display()),
        path: worktree,
        branch: intent.branch.clone(),
    }
}

/// Finds the project whose root contains `cwd` and whose routing is on for
/// this provider.
///
/// Read from `worktree-routing.json`, which the application writes in the same
/// operation as the session itself so the two cannot drift. A version this
/// build does not know is left alone rather than guessed at: passing the
/// command through puts the worktree where the agent asked, which is
/// recoverable, where guessing at a shape could put it anywhere.
fn project_for(support: &Path, cwd: &Path, provider_id: &str) -> Option<ProjectRules> {
    let routing: Value =
        serde_json::from_slice(&std::fs::read(support.join(WORKTREE_ROUTING_FILE)).ok()?).ok()?;
    if routing.get("schemaVersion").and_then(Value::as_u64) != Some(ROUTING_SCHEMA_VERSION) {
        return None;
    }
    let cwd = cwd.to_string_lossy();
    // An entry we cannot read is skipped rather than fatal: one project whose
    // placement this build does not recognize must not stop every other
    // project from routing, which is what returning here would do.
    for project in routing.get("projects")?.as_array()? {
        let Some(root) = project.get("root").and_then(Value::as_str) else {
            continue;
        };
        if *cwd != *root && !cwd.starts_with(&format!("{root}/")) {
            continue;
        }
        // Absent means routed; only an explicit opt-out turns it off, so a
        // provider the application did not know about still gets the rules.
        if project
            .get("routing")
            .and_then(|routing| routing.get(provider_id))
            .and_then(Value::as_bool)
            == Some(false)
        {
            return None;
        }
        let Some(placement) = project.get("placement").and_then(placement) else {
            continue;
        };
        return Some(ProjectRules {
            root: PathBuf::from(root),
            placement,
            bootstrap: project
                .get("bootstrap")
                .and_then(Value::as_array)
                .map(|items| items.iter().filter_map(bootstrap_step).collect())
                .unwrap_or_default(),
        });
    }
    None
}

/// The check commands of the project that owns `cwd`: its own list
/// when it set one, `None` when it did not or no project owns `cwd`, and the
/// caller uses the defaults. A worktree of the project counts as the project
/// (`worktrees` in the routing entry). Read from the same file as the
/// worktree routing, with the same rule for a version this build does not
/// know: it is not guessed at, and the defaults apply.
pub(crate) fn check_patterns(support: &Path, cwd: &Path) -> Option<Vec<String>> {
    let routing: Value =
        serde_json::from_slice(&std::fs::read(support.join(WORKTREE_ROUTING_FILE)).ok()?).ok()?;
    if routing.get("schemaVersion").and_then(Value::as_u64) != Some(ROUTING_SCHEMA_VERSION) {
        return None;
    }
    let cwd = cwd.to_string_lossy();
    let owns = |root: &&str| *cwd == **root || cwd.starts_with(&format!("{root}/"));
    // The deepest directory that owns `cwd` decides, so a project nested in
    // another keeps its own checks.
    let (_, project) = routing
        .get("projects")?
        .as_array()?
        .iter()
        .filter_map(|project| {
            let root = project.get("root").and_then(Value::as_str);
            let worktrees = project
                .get("worktrees")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str);
            let depth = root
                .into_iter()
                .chain(worktrees)
                .filter(owns)
                .map(str::len)
                .max()?;
            Some((depth, project))
        })
        .max_by_key(|(depth, _)| *depth)?;
    project.get("checks")?.as_array().map(|items| {
        items
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    })
}

fn placement(value: &Value) -> Option<Placement> {
    match value.get("kind")?.as_str()? {
        "siblingPrefixed" => Some(Placement::SiblingPrefixed),
        "insideHidden" => Some(Placement::InsideHidden),
        "custom" => Some(Placement::Custom(PathBuf::from(
            value.get("parent")?.as_str()?,
        ))),
        _ => None,
    }
}

impl ProjectRules {
    /// Mirrors `Project.resolvedWorktreeURL(branchLeaf:)`.
    fn worktree_path(&self, branch: &str) -> Option<PathBuf> {
        let leaf = branch.rsplit('/').next().filter(|leaf| !leaf.is_empty())?;
        match &self.placement {
            Placement::SiblingPrefixed => {
                let name = self.root.file_name()?.to_string_lossy();
                Some(self.root.parent()?.join(format!("{name}-{leaf}")))
            }
            Placement::InsideHidden => Some(self.root.join(".worktrees").join(leaf)),
            Placement::Custom(parent) => Some(parent.join(leaf)),
        }
    }
}

fn bootstrap_step(item: &Value) -> Option<BootstrapStep> {
    Some(BootstrapStep {
        command: item.get("command")?.as_str()?.to_owned(),
        cwd: item
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|cwd| !cwd.is_empty())
            .map(str::to_owned),
    })
}

/// Runs each bootstrap step through `/bin/sh -c` in the worktree, as the
/// shell's `eval` did. Failures are diagnostic: they go to stderr and the
/// next step still runs. A step's `cwd` must stay inside the worktree.
fn run_bootstrap(steps: &[BootstrapStep], worktree: &Path) {
    for step in steps {
        if step.cwd.as_deref().is_some_and(escapes_worktree) {
            eprintln!(
                "weir-agent-hook: skipping step, unsafe cwd '{}'",
                step.cwd.as_deref().unwrap_or_default()
            );
            continue;
        }
        let directory = match step_directory(step.cwd.as_deref(), worktree) {
            StepDirectory::Inside(directory) => directory,
            StepDirectory::Outside(resolved) => {
                eprintln!(
                    "weir-agent-hook: skipping step, cwd '{}' resolves to {} outside the worktree",
                    step.cwd.as_deref().unwrap_or_default(),
                    resolved.display()
                );
                continue;
            }
            StepDirectory::Unresolved(path, error) => {
                eprintln!(
                    "weir-agent-hook: bootstrap step could not start in {}: {error}",
                    path.display()
                );
                continue;
            }
        };
        // Both streams go directly to stderr as the shell's `>&2` did.
        // Avoiding a captured stdout preserves output as it is produced and
        // avoids retaining an unbounded bootstrap log in memory.
        match bootstrap_command(step, &directory).status() {
            Ok(_) => {}
            Err(error) => eprintln!(
                "weir-agent-hook: bootstrap step could not start in {}: {error}",
                directory.display()
            ),
        }
    }
}

/// Where a step's directory really is, symlinks resolved.
#[derive(Debug)]
enum StepDirectory {
    /// The directory's real path, inside the worktree's.
    Inside(PathBuf),
    /// The directory's real path, which is not inside the worktree's.
    Outside(PathBuf),
    /// The worktree or the directory has no real path: it does not exist,
    /// or a link in it leads nowhere.
    Unresolved(PathBuf, std::io::Error),
}

/// The real path of the step's directory, checked to lie inside the real
/// path of the worktree, just before the step runs. `escapes_worktree`
/// cannot see a link: the branch just checked out decides what the worktree
/// holds, and a `frontend` there that is a symlink to another project, or a
/// `packages` link that `cwd: "packages/web"` passes through, would run the
/// person's own command in that other project. `canonicalize` is
/// `realpath(3)` and resolves a link in any component. The app's own setup
/// (`WorktreeSetup.stepDirectory`) makes the same check.
///
/// The step is started in the resolved path, so `chdir(2)` follows no link
/// this check did not see. What is left is a component of that path being
/// swapped for a link between this check and the start. We leave that open,
/// as the app does: whatever could make that swap in the window is already
/// running in the person's account in the worktree (an earlier step, or code
/// it started), with no boundary left for the check to keep. It guards the
/// directory a step starts in, not what the step does there.
fn step_directory(cwd: Option<&str>, worktree: &Path) -> StepDirectory {
    let root = match worktree.canonicalize() {
        Ok(root) => root,
        Err(error) => return StepDirectory::Unresolved(worktree.to_path_buf(), error),
    };
    let Some(cwd) = cwd else {
        return StepDirectory::Inside(root);
    };
    let joined = worktree.join(cwd);
    match joined.canonicalize() {
        // Component-wise, so `/a/bc` is not inside `/a/b`.
        Ok(directory) if directory.starts_with(&root) => StepDirectory::Inside(directory),
        Ok(directory) => StepDirectory::Outside(directory),
        Err(error) => StepDirectory::Unresolved(joined, error),
    }
}

fn bootstrap_command(step: &BootstrapStep, directory: &Path) -> Command {
    let mut command = Command::new("/bin/sh");
    command
        .arg("-c")
        .arg(&step.command)
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(Stdio::from(std::io::stderr()))
        .stderr(Stdio::inherit());
    command
}

/// A step `cwd` may only point inside the worktree. The steps are
/// per-machine today, but the same shape may later be shared by a team, so a
/// step must not be able to name a path outside the tree it was created for.
fn escapes_worktree(cwd: &str) -> bool {
    cwd.starts_with('/')
        || cwd == ".."
        || cwd.starts_with("../")
        || cwd.contains("/../")
        || cwd.ends_with("/..")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_step_cwd_may_not_leave_the_worktree() {
        for cwd in ["/etc", "..", "../x", "a/../../b", "a/.."] {
            assert!(escapes_worktree(cwd), "{cwd}");
        }
        for cwd in ["sub", "a/b", "./a", "a/..b"] {
            assert!(!escapes_worktree(cwd), "{cwd}");
        }
    }

    /// A worktree with an `inside` subdirectory, and a directory beside it
    /// that is not in it.
    #[cfg(unix)]
    fn worktree_and_outside() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let scratch = tempfile::tempdir().expect("scratch");
        let worktree = scratch.path().join("worktree");
        let outside = scratch.path().join("outside");
        std::fs::create_dir_all(worktree.join("inside")).expect("inside");
        std::fs::create_dir_all(outside.join("web")).expect("outside");
        (scratch, worktree, outside)
    }

    #[cfg(unix)]
    fn touch_in(cwd: &str) -> BootstrapStep {
        BootstrapStep {
            command: "touch ran".into(),
            cwd: Some(cwd.into()),
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_that_is_a_link_out_of_the_worktree_is_not_run() {
        let (_scratch, worktree, outside) = worktree_and_outside();
        std::os::unix::fs::symlink(&outside, worktree.join("frontend")).expect("link");

        assert!(matches!(
            step_directory(Some("frontend"), &worktree),
            StepDirectory::Outside(_)
        ));
        run_bootstrap(&[touch_in("frontend"), touch_in("inside")], &worktree);

        assert!(!outside.join("ran").exists(), "the step ran outside");
        assert!(
            worktree.join("inside/ran").exists(),
            "a skipped step does not stop later steps"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_through_a_linked_parent_out_of_the_worktree_is_not_run() {
        let (_scratch, worktree, outside) = worktree_and_outside();
        std::os::unix::fs::symlink(&outside, worktree.join("packages")).expect("link");

        assert!(matches!(
            step_directory(Some("packages/web"), &worktree),
            StepDirectory::Outside(_)
        ));
        run_bootstrap(&[touch_in("packages/web")], &worktree);

        assert!(!outside.join("web/ran").exists(), "the step ran outside");
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_that_is_a_link_inside_the_worktree_runs() {
        let (_scratch, worktree, _outside) = worktree_and_outside();
        std::os::unix::fs::symlink("inside", worktree.join("alias")).expect("link");

        run_bootstrap(&[touch_in("alias")], &worktree);

        assert!(worktree.join("inside/ran").exists(), "the step did not run");
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_that_is_missing_is_skipped_and_later_steps_run() {
        let (_scratch, worktree, _outside) = worktree_and_outside();
        std::os::unix::fs::symlink("nowhere", worktree.join("dangling")).expect("link");

        for cwd in ["missing", "dangling"] {
            assert!(matches!(
                step_directory(Some(cwd), &worktree),
                StepDirectory::Unresolved(..)
            ));
        }
        run_bootstrap(
            &[
                touch_in("missing"),
                touch_in("dangling"),
                touch_in("inside"),
            ],
            &worktree,
        );

        assert!(
            worktree.join("inside/ran").exists(),
            "later steps did not run"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_worktree_reached_through_a_link_still_holds_its_subdirectory() {
        let (scratch, worktree, outside) = worktree_and_outside();
        let link = scratch.path().join("link");
        std::os::unix::fs::symlink(&worktree, &link).expect("link");
        std::os::unix::fs::symlink(&outside, worktree.join("frontend")).expect("link");

        assert!(matches!(
            step_directory(Some("inside"), &link),
            StepDirectory::Inside(_)
        ));
        assert!(matches!(
            step_directory(Some("frontend"), &link),
            StepDirectory::Outside(_)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn a_step_cwd_that_is_a_subdirectory_runs() {
        let (_scratch, worktree, _outside) = worktree_and_outside();

        run_bootstrap(&[touch_in("inside")], &worktree);

        assert!(worktree.join("inside/ran").exists(), "the step did not run");
    }

    #[cfg(unix)]
    #[test]
    fn a_sibling_whose_name_starts_with_the_worktree_is_outside() {
        let (scratch, worktree, _outside) = worktree_and_outside();
        let sibling = scratch.path().join("worktree-other");
        std::fs::create_dir_all(&sibling).expect("sibling");
        std::os::unix::fs::symlink(&sibling, worktree.join("next")).expect("link");

        assert!(matches!(
            step_directory(Some("next"), &worktree),
            StepDirectory::Outside(_)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn bootstrap_continues_after_a_failed_step() {
        let worktree_scratch = tempfile::tempdir().expect("scratch");
        let worktree = worktree_scratch.path().to_path_buf();
        let marker = worktree.join("continued");
        let steps = [
            BootstrapStep {
                command: "exit 1".into(),
                cwd: None,
            },
            BootstrapStep {
                command: "touch continued".into(),
                cwd: None,
            },
        ];

        run_bootstrap(&steps, &worktree);

        assert!(marker.exists(), "a failed step does not stop later steps");
    }
}
