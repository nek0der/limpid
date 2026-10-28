//! Where Codex keeps a thread's rollout. Codex files it under its home as
//! `sessions/<year>/<month>/<day>/rollout-<started>-<thread>.jsonl`, the day
//! being the one the thread began, and finds a thread's rollout by that name
//! too (`find_thread_path_by_id_str` in `codex-rs/rollout/src/list.rs`,
//! 0.165.0). A subagent's rollout lies there beside the rest, named by the
//! thread the parent's rollout names it by (`tokens`).

use limpid_agent_model::ListDirectory;
use std::path::{Path, PathBuf};

/// The folder Codex keeps the rollouts of its sessions in, under its home.
const SESSIONS_FOLDER: &str = "sessions";

/// The rollouts of the subagent `threads`, found under the sessions folder
/// that holds the turn's own `rollout`. The days are searched newest first,
/// and only until every thread is found: a subagent usually began during the
/// turn, but one an earlier turn started may have been put to work again
/// days later. `list` lists a folder's entries. A thread none of the days
/// holds is left out, as is every one when `rollout` lies in no sessions
/// folder.
pub(crate) fn subagent_rollouts(
    rollout: &Path,
    threads: &[String],
    list: &ListDirectory<'_>,
) -> Vec<PathBuf> {
    // The rollout, then its day, month, and year, then the sessions folder.
    let Some(sessions) = rollout.ancestors().nth(4).filter(|folder| {
        folder
            .file_name()
            .is_some_and(|name| name == SESSIONS_FOLDER)
    }) else {
        return Vec::new();
    };
    let newest_first = |folder: &Path| {
        let mut entries = list(folder);
        entries.sort_unstable_by(|left, right| right.cmp(left));
        entries
    };
    let suffixes: Vec<String> = threads
        .iter()
        .map(|thread| format!("-{thread}.jsonl"))
        .collect();
    let mut found: Vec<Option<PathBuf>> = vec![None; threads.len()];
    'days: for year in newest_first(sessions) {
        for month in newest_first(&year) {
            for day in newest_first(&month) {
                for path in list(&day) {
                    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                        continue;
                    };
                    if !name.starts_with("rollout-") {
                        continue;
                    }
                    if let Some(index) = suffixes.iter().position(|suffix| name.ends_with(suffix))
                        && found[index].is_none()
                    {
                        found[index] = Some(path.clone());
                    }
                }
                if found.iter().all(Option::is_some) {
                    break 'days;
                }
            }
        }
    }
    found.into_iter().flatten().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_subagent_rollout_is_found_by_its_thread_newest_day_first() {
        let sessions = Path::new("/home/sessions");
        let folders: Vec<(&str, Vec<&str>)> = vec![
            ("/home/sessions", vec!["2025", "2026"]),
            ("/home/sessions/2026", vec!["09", "10"]),
            ("/home/sessions/2025", vec!["12"]),
            ("/home/sessions/2026/10", vec!["27", "28", "29"]),
            ("/home/sessions/2026/09", vec!["30"]),
            ("/home/sessions/2025/12", vec!["31"]),
            (
                "/home/sessions/2026/10/28",
                vec![
                    "rollout-2026-10-28T14-55-55-parent.jsonl",
                    "rollout-2026-10-28T14-56-11-a.jsonl",
                ],
            ),
            (
                "/home/sessions/2026/10/27",
                vec!["rollout-2026-10-27T23-59-58-b.jsonl"],
            ),
            (
                "/home/sessions/2026/09/30",
                vec!["rollout-2026-09-30T10-00-00-c.jsonl", "notes-d.jsonl"],
            ),
            (
                "/home/sessions/2025/12/31",
                vec!["rollout-2025-12-31T10-00-00-d.jsonl"],
            ),
        ];
        let listed = std::cell::RefCell::new(Vec::new());
        let list = |folder: &Path| {
            listed.borrow_mut().push(folder.to_path_buf());
            folders
                .iter()
                .find(|(name, _)| Path::new(name) == folder)
                .map(|(name, entries)| {
                    entries
                        .iter()
                        .map(|entry| Path::new(name).join(entry))
                        .collect()
                })
                .unwrap_or_default()
        };
        let rollout = sessions.join("2026/10/28/rollout-2026-10-28T14-55-55-parent.jsonl");
        // The 29th is empty; a subagent an earlier turn started (d) is
        // found on the day it began, and e is nowhere.
        let threads = ["a", "b", "c", "d", "e"].map(str::to_owned);
        assert_eq!(
            subagent_rollouts(&rollout, &threads, &list),
            vec![
                sessions.join("2026/10/28/rollout-2026-10-28T14-56-11-a.jsonl"),
                sessions.join("2026/10/27/rollout-2026-10-27T23-59-58-b.jsonl"),
                sessions.join("2026/09/30/rollout-2026-09-30T10-00-00-c.jsonl"),
                sessions.join("2025/12/31/rollout-2025-12-31T10-00-00-d.jsonl"),
            ]
        );
        // Once every thread is found, the older days are left unlisted.
        listed.borrow_mut().clear();
        assert_eq!(
            subagent_rollouts(&rollout, &["a".to_owned()], &list),
            vec![sessions.join("2026/10/28/rollout-2026-10-28T14-56-11-a.jsonl")]
        );
        assert!(!listed.borrow().contains(&sessions.join("2026/10/27")));
        // A rollout that lies in no sessions folder finds none.
        let archived = Path::new("/home/archived_sessions/2026/10/28/rollout-x.jsonl");
        assert!(subagent_rollouts(archived, &threads, &list).is_empty());
        assert!(subagent_rollouts(Path::new("rollout.jsonl"), &threads, &list).is_empty());
    }
}
