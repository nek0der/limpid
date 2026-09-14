//! Intercepts the agent's `git worktree add` so the worktree lands where the
//! active project's placement rules say, then runs the project's bootstrap
//! steps and tells the agent where the worktree is.
//!
//! The rules are those of `limpid-pretool-worktree-hook`: anything that is
//! not a confident match passes through untouched, and the only success is a
//! worktree created by Limpid itself, reported with exit status 2 so the
//! provider cancels the original command and shows the message to the model.

use limpid_agent_model::WorktreeIntent;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The routing file version this build reads.
const ROUTING_SCHEMA_VERSION: u64 = 1;

/// What the intercept decided.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InterceptResult {
    /// Let the agent's own command run.
    Passthrough,
    /// Limpid created the worktree; the agent must not run its command. The
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
        message: format!("Limpid created worktree at {}.", worktree.display()),
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
        serde_json::from_slice(&std::fs::read(support.join("worktree-routing.json")).ok()?).ok()?;
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
                "limpid-agent-hook: skipping step, unsafe cwd '{}'",
                step.cwd.as_deref().unwrap_or_default()
            );
            continue;
        }
        let directory = step
            .cwd
            .as_ref()
            .map_or_else(|| worktree.to_path_buf(), |cwd| worktree.join(cwd));
        // Both streams go directly to stderr as the shell's `>&2` did.
        // Avoiding a captured stdout preserves output as it is produced and
        // avoids retaining an unbounded bootstrap log in memory.
        match bootstrap_command(step, &directory).status() {
            Ok(_) => {}
            Err(error) => eprintln!(
                "limpid-agent-hook: bootstrap step could not start in {}: {error}",
                directory.display()
            ),
        }
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

    #[cfg(unix)]
    #[test]
    fn bootstrap_continues_after_a_failed_step() {
        let worktree =
            std::env::temp_dir().join(format!("limpid-bootstrap-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&worktree).expect("worktree");
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
        let _ = std::fs::remove_dir_all(&worktree);
    }
}
