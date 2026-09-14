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

/// The project entry from `state.json` that owns `cwd`.
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
/// is the provider's agent-state directory; `state.json` sits beside it.
#[must_use]
pub fn run(intent: &WorktreeIntent, provider_id: &str, state_dir: &Path) -> InterceptResult {
    let Some(state_json) = state_dir.parent().map(|parent| parent.join("state.json")) else {
        return InterceptResult::Passthrough;
    };
    let cwd = intent
        .cwd
        .clone()
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_default();
    let Some(project) = project_for(&state_json, &cwd, provider_id) else {
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

/// Finds the project whose root contains `cwd` and whose routing toggle for
/// this provider is on. The toggle defaults to on when absent; an explicit
/// `false` is respected, which is why it is read as a boolean and not with
/// an "or true" fallback.
fn project_for(state_json: &Path, cwd: &Path, provider_id: &str) -> Option<ProjectRules> {
    let state: Value = serde_json::from_slice(&std::fs::read(state_json).ok()?).ok()?;
    let cwd = cwd.to_string_lossy();
    let toggle = format!("route{}Worktrees", capitalize(provider_id));
    for project in projects_in(&state) {
        let Some(root) = project
            .get("rootURL")
            .and_then(Value::as_str)
            .map(path_from_file_url)
        else {
            continue;
        };
        let owns = *cwd == *root || cwd.starts_with(&format!("{root}/"));
        if !owns {
            continue;
        }
        if project.get(&toggle).and_then(Value::as_bool) == Some(false) {
            return None;
        }
        let placement = match project.get("worktreePlacement").and_then(Value::as_object) {
            Some(object) if object.contains_key("siblingPrefixed") => Placement::SiblingPrefixed,
            Some(object) if object.contains_key("insideHidden") => Placement::InsideHidden,
            Some(object) => {
                let parent = object
                    .get("custom")
                    .and_then(|custom| custom.get("_0"))
                    .and_then(Value::as_str)
                    .map(path_from_file_url)?;
                Placement::Custom(PathBuf::from(parent))
            }
            None => return None,
        };
        let bootstrap = project
            .get("bootstrap")
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(bootstrap_step).collect())
            .unwrap_or_default();
        return Some(ProjectRules {
            root: PathBuf::from(root),
            placement,
            bootstrap,
        });
    }
    None
}

/// Projects live inside the sidebar's `containers` (`{"kind":"project",
/// "project":{…}}`) since the container redesign; a top-level `projects`
/// array is the shape before it and is still accepted.
fn projects_in(state: &Value) -> Vec<&Value> {
    let mut projects: Vec<&Value> = state
        .get("projects")
        .and_then(Value::as_array)
        .map(|items| items.iter().collect())
        .unwrap_or_default();
    if let Some(containers) = state.get("containers").and_then(Value::as_array) {
        projects.extend(containers.iter().filter_map(|container| {
            (container.get("kind").and_then(Value::as_str) == Some("project"))
                .then(|| container.get("project"))
                .flatten()
        }));
    }
    projects
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
    match item {
        Value::String(command) => Some(BootstrapStep {
            command: command.clone(),
            cwd: None,
        }),
        Value::Object(object) => Some(BootstrapStep {
            command: object.get("cmd")?.as_str()?.to_owned(),
            cwd: object
                .get("cwd")
                .and_then(Value::as_str)
                .filter(|cwd| !cwd.is_empty())
                .map(str::to_owned),
        }),
        _ => None,
    }
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

/// A step `cwd` may only point inside the worktree; `state.json` is
/// per-machine today, but the same shape may later be shared by a team.
fn escapes_worktree(cwd: &str) -> bool {
    cwd.starts_with('/')
        || cwd == ".."
        || cwd.starts_with("../")
        || cwd.contains("/../")
        || cwd.ends_with("/..")
}

/// The path inside a `file://` URL as Swift's `URL` encodes it: percent
/// escapes for spaces and non-ASCII characters, and a trailing slash for a
/// directory. A plain path is returned unchanged so hand-written state files
/// keep working.
fn path_from_file_url(value: &str) -> String {
    let path = value.strip_prefix("file://").unwrap_or(value);
    let path = path.strip_suffix('/').unwrap_or(path);
    String::from_utf8_lossy(&percent_decode(path.as_bytes())).into_owned()
}

/// Decodes `%XX` escapes; a malformed escape is kept literally.
fn percent_decode(bytes: &[u8]) -> Vec<u8> {
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let decoded_byte = (bytes[index] == b'%' && index + 3 <= bytes.len())
            .then(|| bytes.get(index + 1..index + 3))
            .flatten()
            .and_then(|hex| std::str::from_utf8(hex).ok())
            .and_then(|hex| u8::from_str_radix(hex, 16).ok());
        if let Some(byte) = decoded_byte {
            decoded.push(byte);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    decoded
}

fn capitalize(value: &str) -> String {
    let mut characters = value.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_urls_are_decoded_the_way_swift_encodes_them() {
        assert_eq!(
            path_from_file_url("file:///tmp/My%20Project/%E9%96%8B%E7%99%BA/"),
            "/tmp/My Project/開発"
        );
        assert_eq!(path_from_file_url("file:///tmp/repo"), "/tmp/repo");
        assert_eq!(path_from_file_url("/tmp/plain/"), "/tmp/plain");
        assert_eq!(path_from_file_url("/tmp/100%25/x%2"), "/tmp/100%/x%2");
    }

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
