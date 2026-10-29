//! The status line relay: a provider runs it as its status line, it keeps the
//! plan usage the input reports, and it names the person's own status line
//! for the helper to run in its place. What is provider-specific (the input's
//! shape, where settings live, which one wins) is the adapter's
//! (`StatusLineAdapter`); reading the files and keeping the record is ours.
//!
//! The usage is written only when it changed or the stored copy has aged past
//! `REFRESH_SECONDS`: a provider reruns its status line on every message and
//! on a timer, and the interface needs the time it was last seen, not a write
//! per redraw.

use crate::adapter_for;
use crate::env::HookEnv;
use crate::records::{atomic_write, ensure_user_only_directory};
use limpid_agent_model::{
    PlanUsage, ProviderAdapter, SettingsSource, StatusLineAdapter, parse_utc_seconds,
};
use serde_json::{Map, Value};
use std::fs;
use std::path::Path;
use std::time::SystemTime;

/// How old a stored copy may grow before an unchanged reading rewrites it,
/// so the interface's "last seen" stays within a minute of the truth.
const REFRESH_SECONDS: u64 = 60;

/// The largest settings document we read. Settings files are a few
/// kilobytes; the bound keeps a runaway one from being held in memory.
const MAX_SETTINGS_BYTES: usize = 1024 * 1024;

/// The status line command the relay runs after it has read the input, or
/// `None` when there is none to run: the person has no status line, or the
/// provider has no status line we relay.
///
/// Every failure to keep the usage is ignored: the status line the person
/// sees matters more than our copy of a number.
#[must_use]
pub fn run_status_line(
    provider: &str,
    input: &[u8],
    env: &HookEnv,
    now: SystemTime,
) -> Option<String> {
    let adapter = adapter_for(provider)?;
    let status_line = adapter.status_line()?;
    if let (Some(directory), Some(usage)) = (
        env.usage_directory(&adapter.install_recipe()),
        status_line.plan_usage(input, now),
    ) {
        keep_usage(&directory.join(format!("{provider}.json")), &usage);
    }
    let project = status_line.project_directory(input);
    let chosen = user_status_line(env, adapter, status_line, project.as_deref())?;
    status_line.command(&chosen).map(str::to_owned)
}

/// The status line setting the shim launches the provider with: the person's
/// own, as it stands for `working_directory`, with `relay_command` in place of
/// theirs. `None` when they have none: Claude Code keeps a row for a status
/// line even when it prints nothing, so taking an empty slot would add a
/// blank line to their screen.
#[must_use]
pub fn status_line_setting(
    provider: &str,
    env: &HookEnv,
    working_directory: &Path,
    relay_command: &str,
) -> Option<Value> {
    let adapter = adapter_for(provider)?;
    let status_line = adapter.status_line()?;
    let chosen = user_status_line(env, adapter, status_line, Some(working_directory))?;
    Some(status_line.relay(&chosen, relay_command))
}

fn user_status_line(
    env: &HookEnv,
    adapter: &dyn ProviderAdapter,
    status_line: &dyn StatusLineAdapter,
    project: Option<&Path>,
) -> Option<Map<String, Value>> {
    let layers: Vec<Option<Value>> = status_line
        .settings_sources(project)
        .iter()
        .map(|source| read_source(env, adapter, source))
        .collect();
    status_line.user_status_line(&layers)
}

fn read_source(
    env: &HookEnv,
    adapter: &dyn ProviderAdapter,
    source: &SettingsSource,
) -> Option<Value> {
    match source {
        SettingsSource::File(path) => read_settings(path),
        SettingsSource::HomeFile(name) => env
            .provider_home(adapter.home_directory_variable(), adapter.descriptor())
            .and_then(|home| read_settings(&home.join(name))),
        // Inline JSON when it parses, otherwise the path of a file, the way
        // the provider reads its own flag.
        SettingsSource::LaunchVariable(variable) => {
            let value = env.get(variable)?;
            match serde_json::from_str::<Value>(value) {
                Ok(value @ Value::Object(_)) => Some(value),
                Ok(_) => None,
                Err(_) => read_settings(Path::new(value)),
            }
        }
    }
}

fn read_settings(path: &Path) -> Option<Value> {
    let bytes = fs::read(path).ok()?;
    if bytes.len() > MAX_SETTINGS_BYTES {
        return None;
    }
    serde_json::from_slice::<Map<String, Value>>(&bytes)
        .ok()
        .map(Value::Object)
}

fn keep_usage(path: &Path, usage: &PlanUsage) {
    if let Some(stored) = fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<PlanUsage>(&bytes).ok())
    {
        let is_same = stored.windows == usage.windows;
        let age = parse_utc_seconds(&usage.observed_at)
            .zip(parse_utc_seconds(&stored.observed_at))
            .map(|(now, then)| now.saturating_sub(then));
        if is_same && age.is_some_and(|age| age < REFRESH_SECONDS) {
            return;
        }
    }
    let Ok(body) = serde_json::to_vec(usage) else {
        return;
    };
    if let Some(directory) = path.parent() {
        ensure_user_only_directory(directory);
    }
    let _ = atomic_write(path, &body);
}

#[cfg(test)]
mod tests {
    use super::*;
    use limpid_provider_claude::LAUNCH_SETTINGS_VARIABLE;
    use serde_json::json;
    use std::path::PathBuf;
    use std::time::{Duration, UNIX_EPOCH};

    struct Fixture {
        _root: tempfile::TempDir,
        usage: PathBuf,
        project: PathBuf,
        config: PathBuf,
    }

    fn fixture() -> Fixture {
        let root = tempfile::tempdir().expect("temp");
        let usage = root.path().join("usage");
        let project = root.path().join("project");
        let config = root.path().join("config");
        fs::create_dir_all(project.join(".claude")).expect("project");
        fs::create_dir_all(&config).expect("config");
        Fixture {
            usage,
            project,
            config,
            _root: root,
        }
    }

    fn env(fixture: &Fixture, extra: &[(&str, &str)]) -> HookEnv {
        let mut pairs = vec![
            (
                "LIMPID_USAGE_DIR".to_owned(),
                fixture.usage.display().to_string(),
            ),
            (
                "CLAUDE_CONFIG_DIR".to_owned(),
                fixture.config.display().to_string(),
            ),
        ];
        pairs.extend(
            extra
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned())),
        );
        HookEnv::from_pairs(pairs)
    }

    fn input(fixture: &Fixture, used: f64) -> Vec<u8> {
        json!({
            "workspace": { "project_dir": fixture.project },
            "rate_limits": { "five_hour": { "used_percentage": used, "resets_at": 1_793_247_600_u64 } }
        })
        .to_string()
        .into_bytes()
    }

    fn write(path: &Path, value: &Value) {
        fs::write(path, value.to_string()).expect("write");
    }

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(seconds)
    }

    #[test]
    fn the_relay_keeps_the_usage_and_names_the_user_status_line() {
        let fixture = fixture();
        write(
            &fixture.config.join("settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "~/status.sh", "padding": 0 } }),
        );
        let command = run_status_line(
            "claude",
            &input(&fixture, 42.0),
            &env(&fixture, &[]),
            at(100),
        );
        assert_eq!(command.as_deref(), Some("~/status.sh"));
        let stored: PlanUsage =
            serde_json::from_slice(&fs::read(fixture.usage.join("claude.json")).expect("usage"))
                .expect("json");
        assert_eq!(stored.windows[0].kind, "five_hour");
        assert!((stored.windows[0].used_percent - 42.0).abs() < f64::EPSILON);
    }

    #[test]
    fn the_project_and_the_launch_settings_outrank_the_user_file() {
        let fixture = fixture();
        write(
            &fixture.config.join("settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "user.sh" } }),
        );
        write(
            &fixture.project.join(".claude/settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "project.sh" } }),
        );
        let env_plain = env(&fixture, &[]);
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env_plain, at(0)).as_deref(),
            Some("project.sh")
        );
        let launch =
            json!({ "statusLine": { "type": "command", "command": "launch.sh" } }).to_string();
        let env_launch = env(&fixture, &[(LAUNCH_SETTINGS_VARIABLE, &launch)]);
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env_launch, at(0)).as_deref(),
            Some("launch.sh")
        );
    }

    #[test]
    fn a_launch_setting_may_be_a_file() {
        let fixture = fixture();
        let file = fixture.project.join("mine.json");
        write(
            &file,
            &json!({ "statusLine": { "type": "command", "command": "file.sh" } }),
        );
        let path = file.display().to_string();
        let env = env(&fixture, &[(LAUNCH_SETTINGS_VARIABLE, &path)]);
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env, at(0)).as_deref(),
            Some("file.sh")
        );
    }

    #[test]
    fn no_status_line_of_their_own_leaves_nothing_to_run() {
        let fixture = fixture();
        assert_eq!(
            run_status_line("claude", &input(&fixture, 1.0), &env(&fixture, &[]), at(0)),
            None
        );
        assert!(fixture.usage.join("claude.json").exists());
    }

    #[test]
    fn a_provider_without_a_status_line_relays_nothing() {
        let fixture = fixture();
        assert_eq!(
            run_status_line("codex", &input(&fixture, 1.0), &env(&fixture, &[]), at(0)),
            None
        );
        assert!(!fixture.usage.join("codex.json").exists());
    }

    #[test]
    fn an_unchanged_reading_is_rewritten_only_once_it_has_aged() {
        let fixture = fixture();
        let env = env(&fixture, &[]);
        let path = fixture.usage.join("claude.json");
        let observed = |path: &Path| {
            serde_json::from_slice::<PlanUsage>(&fs::read(path).expect("usage"))
                .expect("json")
                .observed_at
        };
        let _ = run_status_line("claude", &input(&fixture, 5.0), &env, at(1_000));
        let first = observed(&path);
        let _ = run_status_line("claude", &input(&fixture, 5.0), &env, at(1_030));
        assert_eq!(observed(&path), first, "unchanged and young: kept");
        let _ = run_status_line("claude", &input(&fixture, 6.0), &env, at(1_031));
        assert_ne!(observed(&path), first, "changed: rewritten");
        let changed = observed(&path);
        let _ = run_status_line("claude", &input(&fixture, 6.0), &env, at(1_100));
        assert_ne!(observed(&path), changed, "aged: rewritten");
    }

    #[test]
    fn the_launch_setting_carries_the_person_s_options_onto_the_relay() {
        let fixture = fixture();
        write(
            &fixture.config.join("settings.json"),
            &json!({ "statusLine": { "type": "command", "command": "user.sh", "padding": 0 } }),
        );
        let setting = status_line_setting(
            "claude",
            &env(&fixture, &[]),
            &fixture.project,
            "/h statusline claude",
        );
        assert_eq!(
            setting,
            Some(json!({ "type": "command", "command": "/h statusline claude", "padding": 0 }))
        );
    }

    #[test]
    fn no_status_line_of_their_own_leaves_the_slot_empty_at_launch() {
        let fixture = fixture();
        let setting = status_line_setting(
            "claude",
            &env(&fixture, &[]),
            &fixture.project,
            "/h statusline claude",
        );
        assert_eq!(setting, None);
    }
}
