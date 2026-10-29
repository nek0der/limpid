//! Claude Code's status line: the plan usage its input carries, and where
//! the person's own status line is set.
//!
//! Claude Code runs one status line command and hands it a JSON document on
//! stdin. For Pro and Max accounts that document carries the plan's usage as
//! `rate_limits.five_hour` and `rate_limits.seven_day`, each with
//! `used_percentage` (0 to 100) and `resets_at` (epoch seconds), once the
//! session's first answer has come back
//! (<https://code.claude.com/docs/en/statusline>). It is the one documented
//! place the plan's usage is given out. So when the person has a status line,
//! the shim puts our relay in its slot, and the relay runs theirs after it
//! has read the usage; `user_status_line` decides which one is theirs the way
//! Claude Code would have.

use limpid_agent_model::{
    PlanUsage, PlanUsageWindow, SettingsSource, StatusLineAdapter, format_utc_seconds, parse_object,
};
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The largest status line input we read. Claude Code's document is a few
/// kilobytes; the bound keeps a runaway one from being held in memory.
const MAX_STATUS_LINE_INPUT_BYTES: usize = 1024 * 1024;

/// The arguments our relay takes after the helper's path, as the shim writes
/// them and `rust/fixtures/contract/shared-values.json` pins. A status line
/// whose command ends with them is ours, which a person's settings can carry
/// only by copying it, and running it would run itself.
pub const RELAY_ARGUMENTS: &str = "statusline claude";

/// The variable the shim moves a person's own `--settings` value into, since
/// its flag has to carry ours.
pub const LAUNCH_SETTINGS_VARIABLE: &str = "LIMPID_CLAUDE_USER_SETTINGS";

/// Claude Code's status line.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct ClaudeStatusLine;

impl StatusLineAdapter for ClaudeStatusLine {
    fn plan_usage(&self, input: &[u8], now: SystemTime) -> Option<PlanUsage> {
        let object = parse_object(input, MAX_STATUS_LINE_INPUT_BYTES).ok()?;
        let limits = object.get("rate_limits")?.as_object()?;
        // In window order rather than the document's, so the shorter window
        // reads first wherever the record is shown.
        let windows: Vec<PlanUsageWindow> =
            [PlanUsageWindow::FIVE_HOUR, PlanUsageWindow::SEVEN_DAY]
                .into_iter()
                .filter_map(|kind| window(kind, limits.get(kind)?))
                .collect();
        if windows.is_empty() {
            return None;
        }
        Some(PlanUsage {
            windows,
            reset_credits: None,
            observed_at: format_utc_seconds(now),
        })
    }

    /// The project directory the input names, else its working directory.
    fn project_directory(&self, input: &[u8]) -> Option<PathBuf> {
        let object = parse_object(input, MAX_STATUS_LINE_INPUT_BYTES).ok()?;
        object
            .get("workspace")
            .and_then(|workspace| workspace.get("project_dir"))
            .and_then(Value::as_str)
            .or_else(|| object.get("cwd").and_then(Value::as_str))
            .filter(|path| !path.is_empty())
            .map(PathBuf::from)
    }

    /// Claude Code's settings precedence
    /// (<https://code.claude.com/docs/en/settings#settings-precedence>):
    /// managed, the launch's `--settings`, the project's local and shared
    /// files, then the user file in the configuration directory, which
    /// `CLAUDE_CONFIG_DIR` moves.
    fn settings_sources(&self, project: Option<&Path>) -> Vec<SettingsSource> {
        let mut sources = vec![
            SettingsSource::File(managed_settings_path()),
            SettingsSource::LaunchVariable(LAUNCH_SETTINGS_VARIABLE),
        ];
        if let Some(project) = project {
            sources.push(SettingsSource::File(
                project.join(".claude").join("settings.local.json"),
            ));
            sources.push(SettingsSource::File(
                project.join(".claude").join("settings.json"),
            ));
        }
        sources.push(SettingsSource::HomeFile("settings.json"));
        sources
    }

    /// The status line of the highest layer that sets one, as Claude Code
    /// takes a setting from the highest layer that has it. `None` when that
    /// one is not a command: Claude Code then runs none either. A layer whose
    /// status line is our relay is passed over, so a copied relay cannot
    /// call itself.
    fn user_status_line(&self, layers: &[Option<Value>]) -> Option<Map<String, Value>> {
        let status_line = layers
            .iter()
            .flatten()
            .filter_map(|settings| settings.get("statusLine"))
            .find(|status_line| !is_relay(status_line))?
            .as_object()?;
        self.command(status_line)?;
        Some(status_line.clone())
    }

    fn command<'a>(&self, status_line: &'a Map<String, Value>) -> Option<&'a str> {
        if status_line.get("type").and_then(Value::as_str) != Some("command") {
            return None;
        }
        status_line
            .get("command")
            .and_then(Value::as_str)
            .filter(|command| !command.trim().is_empty())
    }

    /// Their setting with our command, so the options they chose (`padding`)
    /// still apply to what they see.
    fn relay(&self, user: &Map<String, Value>, relay_command: &str) -> Value {
        let mut setting = user.clone();
        setting.insert("command".to_owned(), Value::from(relay_command));
        Value::Object(setting)
    }
}

/// Whether a status line setting is our relay.
fn is_relay(status_line: &Value) -> bool {
    status_line
        .get("command")
        .and_then(Value::as_str)
        .is_some_and(|command| command.trim_end().ends_with(RELAY_ARGUMENTS))
}

fn window(kind: &str, value: &Value) -> Option<PlanUsageWindow> {
    let value = value.as_object()?;
    let used_percent = value.get("used_percentage")?.as_f64()?;
    if !used_percent.is_finite() {
        return None;
    }
    let resets_at = value
        .get("resets_at")
        .and_then(Value::as_u64)
        .map(|seconds| format_utc_seconds(UNIX_EPOCH + Duration::from_secs(seconds)));
    Some(PlanUsageWindow {
        kind: kind.to_owned(),
        used_percent,
        resets_at,
    })
}

/// The managed settings file of this system
/// (<https://code.claude.com/docs/en/settings#settings-files>). Only the
/// file: a status line set through drop-in files beside it or a device
/// management profile is not seen, and the person's own is run instead.
fn managed_settings_path() -> PathBuf {
    if cfg!(target_os = "macos") {
        PathBuf::from("/Library/Application Support/ClaudeCode/managed-settings.json")
    } else if cfg!(windows) {
        PathBuf::from(r"C:\Program Files\ClaudeCode\managed-settings.json")
    } else {
        PathBuf::from("/etc/claude-code/managed-settings.json")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(seconds)
    }

    #[test]
    fn plan_usage_reads_both_windows_in_window_order() {
        let input = json!({
            "rate_limits": {
                "seven_day": { "used_percentage": 83, "resets_at": 1_793_822_400_u64 },
                "five_hour": { "used_percentage": 42.5, "resets_at": 1_793_247_600_u64 }
            }
        })
        .to_string();
        let usage = ClaudeStatusLine
            .plan_usage(input.as_bytes(), at(1_793_240_000))
            .expect("usage");
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].kind, "five_hour");
        assert!((usage.windows[0].used_percent - 42.5).abs() < f64::EPSILON);
        assert_eq!(
            usage.windows[0].resets_at.as_deref(),
            Some("2026-10-29T04:20:00Z")
        );
        assert_eq!(usage.windows[1].kind, "seven_day");
        assert_eq!(usage.observed_at, "2026-10-29T02:13:20Z");
    }

    #[test]
    fn plan_usage_keeps_the_window_that_is_still_reported() {
        // Claude Code drops a window from the document once it has reset.
        let input = json!({ "rate_limits": { "seven_day": { "used_percentage": 4 } } }).to_string();
        let usage = ClaudeStatusLine
            .plan_usage(input.as_bytes(), at(0))
            .expect("usage");
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].kind, "seven_day");
        assert_eq!(usage.windows[0].resets_at, None);
    }

    #[test]
    fn plan_usage_is_none_without_rate_limits() {
        for input in [
            json!({ "model": { "display_name": "Opus" } }).to_string(),
            json!({ "rate_limits": {} }).to_string(),
            json!({ "rate_limits": { "five_hour": { "resets_at": 1 } } }).to_string(),
            "not json".to_owned(),
        ] {
            assert_eq!(
                ClaudeStatusLine.plan_usage(input.as_bytes(), at(0)),
                None,
                "{input}"
            );
        }
    }

    #[test]
    fn project_directory_prefers_the_project_over_the_working_directory() {
        let input = json!({ "cwd": "/w/sub", "workspace": { "project_dir": "/w" } }).to_string();
        assert_eq!(
            ClaudeStatusLine.project_directory(input.as_bytes()),
            Some(PathBuf::from("/w"))
        );
        let input = json!({ "cwd": "/w/sub" }).to_string();
        assert_eq!(
            ClaudeStatusLine.project_directory(input.as_bytes()),
            Some(PathBuf::from("/w/sub"))
        );
    }

    #[test]
    fn settings_sources_follow_claude_precedence() {
        let sources = ClaudeStatusLine.settings_sources(Some(Path::new("/w")));
        assert_eq!(
            sources[1..],
            [
                SettingsSource::LaunchVariable(LAUNCH_SETTINGS_VARIABLE),
                SettingsSource::File(PathBuf::from("/w/.claude/settings.local.json")),
                SettingsSource::File(PathBuf::from("/w/.claude/settings.json")),
                SettingsSource::HomeFile("settings.json"),
            ]
        );
        assert_eq!(ClaudeStatusLine.settings_sources(None).len(), 3);
    }

    #[test]
    fn user_status_line_takes_the_highest_layer_that_sets_a_command() {
        let user =
            json!({ "statusLine": { "type": "command", "command": "user.sh", "padding": 0 } });
        let project = json!({ "statusLine": { "type": "command", "command": "project.sh" } });
        let layers = [None, None, None, Some(project), Some(user)];
        let chosen = ClaudeStatusLine
            .user_status_line(&layers)
            .expect("a status line");
        assert_eq!(ClaudeStatusLine.command(&chosen), Some("project.sh"));
    }

    #[test]
    fn user_status_line_skips_layers_that_set_none() {
        let layers = [
            None,
            Some(json!({ "permissions": {} })),
            Some(json!({ "statusLine": { "type": "command", "command": "user.sh" } })),
        ];
        let chosen = ClaudeStatusLine
            .user_status_line(&layers)
            .expect("a status line");
        assert_eq!(ClaudeStatusLine.command(&chosen), Some("user.sh"));
        assert_eq!(
            ClaudeStatusLine.user_status_line(&[None, Some(json!({}))]),
            None
        );
    }

    #[test]
    fn user_status_line_is_none_when_the_highest_one_is_not_a_command() {
        // The higher layer's setting is the one Claude Code takes, so the
        // lower command does not run there either.
        for higher in [
            json!({ "statusLine": { "type": "command", "command": "  " } }),
            json!({ "statusLine": "nonsense" }),
        ] {
            let lower = json!({ "statusLine": { "type": "command", "command": "user.sh" } });
            assert_eq!(
                ClaudeStatusLine.user_status_line(&[Some(higher.clone()), Some(lower)]),
                None,
                "{higher}"
            );
        }
    }

    #[test]
    fn user_status_line_never_picks_our_own_relay() {
        let relay = json!({ "statusLine": { "type": "command",
            "command": format!("/tmp/x/AgentIntegrationHookHelper {RELAY_ARGUMENTS}") } });
        let user = json!({ "statusLine": { "type": "command", "command": "user.sh" } });
        assert_eq!(
            ClaudeStatusLine.user_status_line(&[Some(relay.clone())]),
            None
        );
        let chosen = ClaudeStatusLine
            .user_status_line(&[Some(relay), Some(user)])
            .expect("the person's own below the copied relay");
        assert_eq!(ClaudeStatusLine.command(&chosen), Some("user.sh"));
    }

    /// The shim writes the arguments and the app's tests check its output
    /// against the same file, so the three agree on what our relay is.
    #[test]
    fn the_relay_arguments_are_the_ones_the_shim_writes() {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures/contract/shared-values.json");
        let shared: Value =
            serde_json::from_slice(&std::fs::read(path).expect("the shared values file"))
                .expect("the shared values decode");
        assert_eq!(
            shared["claudeStatusLineRelayArguments"].as_str(),
            Some(RELAY_ARGUMENTS)
        );
    }

    #[test]
    fn relay_keeps_the_person_s_options() {
        let user = json!({ "type": "command", "command": "user.sh", "padding": 0 });
        let relay =
            ClaudeStatusLine.relay(user.as_object().expect("object"), "/h statusline claude");
        assert_eq!(
            relay,
            json!({ "type": "command", "command": "/h statusline claude", "padding": 0 })
        );
    }
}
